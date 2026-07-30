defmodule RintoPMOWeb.V1.ProjectRepoJSON do
  alias RintoPMO.Projects.ProjectRepo

  def index(%{project_repos: project_repos}) do
    %{data: Enum.map(project_repos, &data/1)}
  end

  def show(%{project_repo: project_repo}) do
    %{data: data(project_repo)}
  end

  def data(%ProjectRepo{} = project_repo) do
    %{
      id: project_repo.id,
      project_id: project_repo.project_id,
      name: project_repo.name,
      git_url: project_repo.git_url,
      branch: project_repo.branch,
      credential_id: project_repo.credential_id,
      last_synced_at: project_repo.last_synced_at,
      last_sync_error: project_repo.last_sync_error,
      inserted_at: project_repo.inserted_at,
      updated_at: project_repo.updated_at
    }
  end
end
