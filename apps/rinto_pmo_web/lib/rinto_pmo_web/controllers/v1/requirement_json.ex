defmodule RintoPMOWeb.V1.RequirementJSON do
  alias RintoPMO.Requirements.Requirement

  def index(%{requirements: requirements}), do: %{data: Enum.map(requirements, &data/1)}
  def show(%{requirement: requirement}), do: %{data: data(requirement)}

  defp data(%Requirement{} = requirement) do
    Map.take(requirement, [
      :id,
      :project_id,
      :title,
      :description,
      :status,
      :archived_at,
      :inserted_at,
      :updated_at
    ])
  end
end
