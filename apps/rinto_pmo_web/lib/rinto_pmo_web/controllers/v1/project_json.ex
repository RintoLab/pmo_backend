defmodule RintoPMOWeb.V1.ProjectJSON do
  alias RintoPMO.Projects.Project
  alias RintoPMOWeb.V1.ProjectRepoJSON

  def index(%{projects: projects}) do
    %{data: Enum.map(projects, &summary/1)}
  end

  def show(%{project: project}) do
    %{data: data(project)}
  end

  defp summary(%Project{} = project) do
    %{
      id: project.id,
      name: project.name,
      slug: project.slug,
      description: project.description,
      status: project.status,
      inserted_at: project.inserted_at,
      updated_at: project.updated_at
    }
  end

  defp data(%Project{} = project) do
    project
    |> summary()
    |> Map.put(:repos, render_repos(project.repos))
  end

  defp render_repos(repos) when is_list(repos), do: Enum.map(repos, &ProjectRepoJSON.data/1)
  defp render_repos(%Ecto.Association.NotLoaded{}), do: []
end
