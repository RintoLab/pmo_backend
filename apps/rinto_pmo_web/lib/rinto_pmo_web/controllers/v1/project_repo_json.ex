defmodule RintoPMOWeb.V1.ProjectRepoJSON do
  alias RintoPMO.Projects.ProjectRepo

  def index(%{project_repos: project_repos}) do
    %{data: Enum.map(project_repos, &data/1)}
  end

  def show(%{project_repo: project_repo}) do
    %{data: data(project_repo)}
  end

  @doc """
  Where a branch is on this machine, and how current it is.

  `commit` and `synced_at` are what makes an answer drawn from this checkout
  attributable: the first says which code was read, the second when it was last
  known to match the remote. `sync_error` is present only when this copy could
  not be refreshed, and its presence is the whole warning -- a reader that
  ignores it will describe a stale tree as if it were current.
  """
  def checkout(%{checkout: checkout}) do
    %{
      data: %{
        path: checkout.path,
        branch: checkout.branch,
        commit: checkout.commit,
        synced_at: checkout.synced_at,
        sync_error: checkout.sync_error
      }
    }
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
