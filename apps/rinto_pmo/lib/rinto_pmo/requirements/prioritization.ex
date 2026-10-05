defmodule RintoPMO.Requirements.Prioritization do
  @moduledoc "Sets one requirement's priority using its context, without a review stage."
  import Ecto.Query
  alias RintoPMO.AIRoles
  alias RintoPMO.Jobs
  alias RintoPMO.Projects.Project
  alias RintoPMO.Repo
  alias RintoPMO.Requirements
  alias RintoPMO.Requirements.EstimationContext
  alias RintoPMO.Requirements.PrioritizationWorker
  alias RintoPMO.Requirements.Requirement
  alias RintoPMO.Requirements.Tree
  alias RintoPMO.Utils

  def request(value) do
    with {:ok, id} <- cast_id(value),
         {:ok, requirement, _tree} <- resolve(id),
         {:ok, _role} <- role(),
         {:ok, job} <-
           %{requirement_id: id, revision: revision(requirement)}
           |> PrioritizationWorker.new()
           |> Oban.insert() do
      {:ok, Jobs.describe(Repo.reload!(job))}
    end
  end

  def run(%Oban.Job{args: %{"requirement_id" => id, "revision" => revision}}) do
    with {:ok, role} <- role(),
         {:ok, requirement, tree} <- resolve(id),
         :ok <- unchanged(requirement, revision),
         {:ok, input} <- context(requirement, tree),
         {:ok, result} <-
           Utils.module(:requirement_prioritizer).prioritize(input,
             provider: role.provider,
             model: role.model,
             thinking: role.thinking_level,
             system_prompt: role.system_prompt
           ),
         {:ok, priority} <- validate(result, id),
         {:ok, _} <- write_priority(id, revision, input, priority) do
      :ok
    end
  end

  defp write_priority(id, revision, input, priority) do
    Repo.transact(fn ->
      Repo.one(from r in Requirement, where: r.id == ^id, lock: "FOR UPDATE")

      with {:ok, requirement, tree} <- resolve(id),
           :ok <- unchanged(requirement, revision),
           {:ok, current_input} <- context(requirement, tree),
           :ok <- same_context(input, current_input) do
        Requirements.update_requirement(requirement, %{priority: priority})
      else
        {:error, code, details} -> {:error, {code, details}}
        error -> error
      end
    end)
  end

  defp context(requirement, tree) do
    project = Repo.get!(Project, requirement.project_id)

    with {:ok, documents, _fingerprint} <- EstimationContext.load(requirement, tree) do
      input = %{
        id: requirement.id,
        title: requirement.title,
        description: requirement.description,
        project: Map.take(project, [:id, :name, :description]),
        context: documents
      }

      if byte_size(Jason.encode!(input)) <= 200_000,
        do: {:ok, input},
        else: {:error, "priority context exceeds 200 KB; narrow the requirement"}
    end
  end

  defp validate([%{"requirement_id" => id, "priority" => priority}], id)
       when is_integer(priority) and priority in 1..5,
       do: {:ok, priority}

  defp validate(_, _),
    do: {:error, "AI must return one priority from 1 to 5 for this requirement"}

  defp resolve(id) do
    case Repo.get(Requirement, id) do
      nil ->
        {:error, :not_found}

      requirement ->
        tree = Tree.load([requirement.project_id])
        project = Repo.get!(Project, requirement.project_id)

        if project.status == :active and Enum.all?(Tree.ancestry(tree, id), &Tree.open?/1),
          do: {:ok, requirement, tree},
          else:
            {:error, :bad_request,
             %{id: ["must belong to an open hierarchy in an active project"]}}
    end
  end

  # A manual edit while queued or while the model is running takes precedence.
  defp revision(requirement) do
    requirement
    |> Map.take([:title, :description, :priority, :updated_at])
    |> :erlang.term_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp unchanged(requirement, revision) do
    if revision(requirement) == revision,
      do: :ok,
      else: {:error, "Requirement changed during AI prioritization; kept the current priority"}
  end

  defp same_context(input, input), do: :ok
  defp same_context(_, _), do: {:error, "Requirement context changed; kept the current priority"}

  defp cast_id(value) do
    case Ecto.UUID.cast(value) do
      {:ok, id} -> {:ok, id}
      :error -> {:error, :bad_request, %{id: ["must be a requirement UUID"]}}
    end
  end

  defp role do
    case AIRoles.get_role("requirement_prioritization") do
      nil -> {:error, :no_prioritization_ai, %{}}
      role -> {:ok, role}
    end
  end
end
