defmodule RintoPMO.Requirements.Scheduling do
  @moduledoc "Adds a requirement's unplanned work to the schedule in one atomic operation."

  alias RintoPMO.Projects.Project
  alias RintoPMO.Repo
  alias RintoPMO.Requirements.Requirement
  alias RintoPMO.Requirements.Tree
  alias RintoPMO.Tasks

  def request(value, attrs) do
    with {:ok, id} <- cast_id(value),
         {:ok, day} <- cast_day(attrs),
         {:ok, ids} <- resolve(id),
         {:ok, result} <- Tasks.schedule_unplanned_tasks(ids, day) do
      {:ok, Map.merge(result, %{requirement_id: id, planned_start_on: day})}
    end
  end

  defp resolve(id) do
    case Repo.get(Requirement, id) do
      nil ->
        {:error, :not_found}

      requirement ->
        tree = Tree.load([requirement.project_id])
        project = Repo.get!(Project, requirement.project_id)

        if project.status == :active and Enum.all?(Tree.ancestry(tree, id), &Tree.open?/1),
          do: {:ok, Tree.descendants(tree, [id], true)},
          else:
            {:error, :bad_request,
             %{id: ["must belong to an open hierarchy in an active project"]}}
    end
  end

  defp cast_id(value) do
    case Ecto.UUID.cast(value) do
      {:ok, id} -> {:ok, id}
      :error -> {:error, :bad_request, %{id: ["must be a requirement UUID"]}}
    end
  end

  defp cast_day(%{"planned_start_on" => value} = attrs)
       when is_binary(value) and map_size(attrs) == 1 do
    case Date.from_iso8601(value) do
      {:ok, day} -> {:ok, day}
      {:error, _} -> invalid_day()
    end
  end

  defp cast_day(_attrs), do: invalid_day()

  defp invalid_day,
    do: {:error, :bad_request, %{planned_start_on: ["supply only a required ISO 8601 date"]}}
end
