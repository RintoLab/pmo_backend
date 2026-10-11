defmodule RintoPMO.Tasks.DocumentSync do
  @moduledoc """
  Applies structured work read from an adopted task document, independent of
  Markdown layout. The caller supplies the revision it actually read.

  Only title, description and Repo are synchronized. Last-imported values let
  us distinguish document changes from manual task edits. Omitted items and
  all execution fields are preserved. A conflict rolls back the entire batch.
  """
  import Ecto.Query
  alias Ecto.Changeset
  alias RintoPMO.Documents.Document
  alias RintoPMO.Documents.Revisions
  alias RintoPMO.Projects.Project
  alias RintoPMO.Repo
  alias RintoPMO.Requirements.Requirement
  alias RintoPMO.Tasks
  alias RintoPMO.Tasks.DocumentEntry
  alias RintoPMO.Tasks.SyncInput
  alias RintoPMO.Tasks.Task

  @fields ~w(title description repo_id)

  def sync(%Document{id: id}, attrs) do
    with {:ok, input} <- SyncInput.parse(attrs) do
      Repo.transact(fn -> sync_locked(id, input) end)
      |> unwrap_error()
    end
  end

  defp sync_locked(id, input) do
    document = Repo.one!(from d in Document, where: d.id == ^id, lock: "FOR UPDATE")

    with {:ok, project} <- validate_scope(document),
         :ok <- validate_revision(document, input.base_revision_id),
         {:ok, results} <- sync_items(document, project, input) do
      {:ok, %{document_id: id, revision_id: input.base_revision_id, items: results}}
    else
      {:error, code, details} -> {:error, {code, details}}
      error -> error
    end
  end

  defp validate_scope(
         %Document{kind: :task, archived_at: nil, status: :formal, requirement_id: id} = document
       )
       when is_binary(id) do
    project = Repo.one!(from p in Project, where: p.id == ^document.project_id, lock: "FOR SHARE")

    requirement =
      Repo.one(from r in Requirement, where: r.id == ^document.requirement_id, lock: "FOR UPDATE")

    cond do
      project.status != :active ->
        invalid(:project_id, "must belong to an active project")

      is_nil(requirement) ->
        invalid(:requirement_id, "must belong to an open leaf requirement")

      requirement.project_id != project.id or requirement.archived_at != nil or
          requirement.status not in [:draft, :analyzed, :active] ->
        invalid(:requirement_id, "must belong to an open leaf requirement in this project")

      Repo.exists?(
        from r in Requirement, where: r.parent_id == ^requirement.id and is_nil(r.archived_at)
      ) ->
        invalid(:requirement_id, "must be a leaf requirement")

      true ->
        {:ok, project}
    end
  end

  defp validate_scope(_document),
    do: invalid(:document, "must be an unarchived, adopted task document")

  defp validate_revision(document, revision_id) do
    current =
      Revisions.latest()
      |> where([revision], revision.document_id == ^document.id)
      |> select([revision], revision.id)
      |> Repo.one!()

    if current == revision_id,
      do: :ok,
      else:
        {:error, :stale_document, %{base_revision_id: revision_id, latest_revision_id: current}}
  end

  defp sync_items(document, project, input) do
    Enum.reduce_while(input.tasks, {:ok, []}, fn item, {:ok, results} ->
      case sync_item(document, project, input.base_revision_id, item) do
        {:ok, result} ->
          {:cont, {:ok, [result | results]}}

        {:error, %Changeset{} = changeset} ->
          errors = changeset_errors(changeset)
          {:halt, {:error, :validation_error, %{key: item.key, errors: errors}}}

        error ->
          {:halt, error}
      end
    end)
    |> case do
      {:ok, results} -> {:ok, Enum.reverse(results)}
      error -> error
    end
  end

  defp changeset_errors(changeset),
    do: Changeset.traverse_errors(changeset, fn {message, _opts} -> message end)

  defp sync_item(document, project, revision_id, item) do
    desired =
      Map.new(@fields, fn key -> {key, Map.fetch!(item, String.to_existing_atom(key))} end)

    entry = Repo.get_by(DocumentEntry, document_id: document.id, key: item.key)

    case entry do
      nil -> create_item(document, project, revision_id, item.key, desired)
      entry -> update_item(document, revision_id, entry, desired)
    end
  end

  defp create_item(document, project, revision_id, key, desired) do
    attrs =
      Map.merge(desired, %{
        "requirement_id" => document.requirement_id,
        "document_id" => document.id
      })

    with {:ok, task} <- Tasks.create_task(project, attrs),
         {:ok, _entry} <-
           Repo.insert(%DocumentEntry{
             document_id: document.id,
             key: key,
             task_id: task.id,
             revision_id: revision_id,
             baseline: desired
           }) do
      {:ok, %{key: key, action: :created, task: task}}
    end
  end

  defp update_item(_document, _revision_id, %DocumentEntry{task_id: nil} = entry, _desired),
    do: conflict(entry, "the task was deleted; use a new key for replacement work")

  defp update_item(document, revision_id, entry, desired) do
    case Repo.one(from t in Task, where: t.id == ^entry.task_id, lock: "FOR UPDATE") do
      nil -> conflict(entry, "the task was deleted during synchronization")
      task -> merge_item(document, revision_id, entry, desired, task)
    end
  end

  defp merge_item(document, revision_id, entry, desired, task) do
    changes = Map.reject(desired, fn {key, value} -> entry.baseline[key] == value end)

    with :ok <- validate_interpretation(entry, revision_id, changes),
         :ok <- validate_existing(document, entry, task, changes),
         {:ok, updated} <- update_task(task, changes),
         {:ok, _entry} <-
           entry |> Changeset.change(baseline: desired, revision_id: revision_id) |> Repo.update() do
      action = if map_size(changes) == 0, do: :unchanged, else: :updated
      {:ok, %{key: entry.key, action: action, task: updated}}
    end
  end

  defp validate_interpretation(entry, revision_id, changes) do
    if entry.revision_id == revision_id and map_size(changes) > 0,
      do:
        conflict(
          entry,
          "the same revision produced different content; revise the document or explicitly edit the task"
        ),
      else: :ok
  end

  defp validate_existing(document, entry, task, changes) do
    conflicts =
      Enum.filter(Map.keys(changes), fn key ->
        current = Map.fetch!(task, String.to_existing_atom(key))
        current != entry.baseline[key] and current != changes[key]
      end)

    cond do
      task.requirement_id != document.requirement_id ->
        conflict(entry, "the document's requirement has changed")

      map_size(changes) == 0 ->
        :ok

      task.status != :open ->
        conflict(entry, "work has started or finished; update it explicitly")

      conflicts != [] ->
        conflict(entry, "the task was edited manually", conflicts)

      true ->
        :ok
    end
  end

  defp update_task(task, changes) when map_size(changes) == 0, do: {:ok, Tasks.get_task!(task.id)}
  defp update_task(task, changes), do: Tasks.update_task(task, changes)

  defp invalid(field, message), do: {:error, :validation_error, %{field => [message]}}

  defp conflict(entry, reason, fields \\ []),
    do:
      {:error, :task_sync_conflict,
       %{key: entry.key, task_id: entry.task_id, reason: reason, fields: fields}}

  # Repo.transact expects a two-element error tuple at its boundary.
  defp unwrap_error({:error, {code, details}}), do: {:error, code, details}
  defp unwrap_error(result), do: result
end
