defmodule RintoPMO.Requirements.Estimation do
  @moduledoc "Queues missing task estimates once per open leaf requirement."
  import Ecto.Query

  alias RintoPMO.AIRoles
  alias RintoPMO.Projects.Project
  alias RintoPMO.Repo
  alias RintoPMO.Requirements.EstimationWorker
  alias RintoPMO.Requirements.Requirement
  alias RintoPMO.Requirements.Tree
  alias RintoPMO.Tasks.Task

  def request(ids) do
    with {:ok, ids} <- cast_ids(ids),
         {:ok, leaves} <- resolve(ids),
         entries = Enum.map(leaves, &entry/1),
         :ok <- configured(entries) do
      Repo.transact(fn -> enqueue(entries) end)
    end
  end

  def targets(id) do
    Repo.all(
      from task in Task,
        where:
          task.requirement_id == ^id and task.kind == :work and
            task.status in [:open, :in_progress] and is_nil(task.estimate_optimistic),
        order_by: task.id
    )
  end

  def eligible?(requirement, tree) do
    MapSet.member?(Tree.leaf_ids(tree), requirement.id) and
      Enum.all?(Tree.ancestry(tree, requirement.id), &Tree.open?/1) and
      Repo.get!(Project, requirement.project_id).status == :active
  end

  defp cast_ids(ids) when is_list(ids) and length(ids) in 1..100 do
    cast = Enum.map(ids, &Ecto.UUID.cast/1)

    if Enum.all?(cast, &match?({:ok, _}, &1)),
      do: {:ok, cast |> Enum.map(&elem(&1, 1)) |> Enum.uniq()},
      else: invalid("must contain only requirement UUIDs")
  end

  defp cast_ids(_ids), do: invalid("must contain 1 to 100 requirement UUIDs")

  defp resolve(ids) do
    roots = Repo.all(from requirement in Requirement, where: requirement.id in ^ids)
    tree = Tree.load(Enum.uniq(Enum.map(roots, & &1.project_id)))

    active =
      Enum.all?(roots, fn root ->
        Enum.all?(Tree.ancestry(tree, root.id), &Tree.open?/1) and
          Repo.get!(Project, root.project_id).status == :active
      end)

    if length(roots) == length(ids) and active do
      descendants = MapSet.new(Tree.descendants(tree, ids, true))
      leaves = Tree.leaf_ids(tree)

      {:ok,
       Enum.filter(tree, &(MapSet.member?(descendants, &1.id) and MapSet.member?(leaves, &1.id)))}
    else
      invalid(
        "every selection must exist and belong to an open requirement hierarchy in an active project"
      )
    end
  end

  defp entry(requirement) do
    work =
      Repo.all(
        from task in Task, where: task.requirement_id == ^requirement.id and task.kind == :work
      )

    pending = Enum.filter(work, &(&1.status in [:open, :in_progress]))

    reason =
      cond do
        work == [] -> :no_tasks
        pending == [] -> :no_pending_tasks
        Enum.all?(pending, &(not is_nil(&1.estimate_optimistic))) -> :already_estimated
        true -> nil
      end

    %{requirement_id: requirement.id, title: requirement.title, job: nil, reason: reason}
  end

  defp configured(entries) do
    if Enum.any?(entries, &is_nil(&1.reason)) and is_nil(AIRoles.get_role("task_estimation")),
      do: {:error, :no_estimation_ai, %{}},
      else: :ok
  end

  defp enqueue(entries) do
    Enum.reduce_while(entries, {:ok, []}, fn entry, {:ok, acc} ->
      case enqueue_entry(entry) do
        {:ok, result} -> {:cont, {:ok, [result | acc]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, entries} -> {:ok, Enum.reverse(entries)}
      error -> error
    end
  end

  defp enqueue_entry(%{reason: nil} = entry) do
    with {:ok, job} <-
           %{requirement_id: entry.requirement_id} |> EstimationWorker.new() |> Oban.insert() do
      {:ok, %{entry | job: RintoPMO.Jobs.describe(Repo.reload!(job))}}
    end
  end

  defp enqueue_entry(entry), do: {:ok, entry}
  defp invalid(reason), do: {:error, :bad_request, %{requirement_ids: [reason]}}
end
