defmodule RintoPMOWeb.V1.RequirementJSON do
  alias RintoPMO.Projects.Project
  alias RintoPMO.Requirements.Requirement
  alias RintoPMOWeb.V1.DocumentJSON

  def index(%{requirements: requirements}), do: %{data: Enum.map(requirements, &data/1)}

  def show(%{requirement: requirement, documents: documents}) do
    %{data: Map.put(data(requirement), :documents, Enum.map(documents, &DocumentJSON.summary/1))}
  end

  defp data(%Requirement{} = requirement) do
    fields =
      Map.take(requirement, [
        :id,
        :project_id,
        :parent_id,
        :child_count,
        :title,
        :description,
        :priority,
        :status,
        :archived_at,
        :inserted_at,
        :updated_at
      ])
      |> Map.put(:workload, requirement.workload)

    case requirement.project do
      %Project{} = project ->
        Map.put(fields, :project, Map.take(project, [:id, :slug, :name, :status]))

      _not_loaded ->
        fields
    end
  end
end
