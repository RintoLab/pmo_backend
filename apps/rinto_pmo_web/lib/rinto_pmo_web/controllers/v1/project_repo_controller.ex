defmodule RintoPMOWeb.V1.ProjectRepoController do
  use RintoPMOWeb, :controller

  alias RintoPMO.Jobs
  alias RintoPMO.Utils
  alias RintoPMOWeb.V1.JobJSON

  def index(conn, %{"project_slug" => project_slug}) do
    context = Utils.module(:projects)
    project = context.get_active_project_by_slug!(project_slug)
    project_repos = context.list_project_repos(project)

    render(conn, :index, project_repos: project_repos)
  end

  def show(conn, %{"project_slug" => project_slug, "id" => id}) do
    context = Utils.module(:projects)
    project = context.get_active_project_by_slug!(project_slug)
    project_repo = context.get_project_repo!(project, id)

    render(conn, :show, project_repo: project_repo)
  end

  def create(conn, %{"project_slug" => project_slug} = params) do
    context = Utils.module(:projects)
    project = context.get_active_project_by_slug!(project_slug)
    project_repo_params = Map.delete(params, "project_slug")

    with {:ok, project_repo} <- context.create_project_repo(project, project_repo_params) do
      conn
      |> put_status(:created)
      |> render(:show, project_repo: project_repo)
    end
  end

  def update(conn, %{"project_slug" => project_slug, "id" => id} = params) do
    context = Utils.module(:projects)
    project = context.get_active_project_by_slug!(project_slug)
    project_repo = context.get_project_repo!(project, id)
    project_repo_params = Map.drop(params, ["project_slug", "id"])

    with {:ok, project_repo} <- context.update_project_repo(project_repo, project_repo_params) do
      render(conn, :show, project_repo: project_repo)
    end
  end

  @doc """
  Asks for this repository's working copy to be brought up to date.

  Answers `202` with the *job*, not the result: a first clone of a repository on
  the public internet is tens of seconds, and nothing should hold a browser open
  for it. Watch `last_synced_at` and `last_sync_error` on the repository itself
  for the outcome, or `GET /jobs/{job_id}` for the attempt.

  This is the one somebody presses after fixing a credential.
  `POST .../checkout` is the agent's: it waits, because it needs the path.
  """
  def sync(conn, %{"project_slug" => project_slug, "id" => id}) do
    context = Utils.module(:projects)
    project = context.get_active_project_by_slug!(project_slug)
    project_repo = context.get_project_repo!(project, id)

    case Utils.module(:workspace).request_sync(project_repo) do
      # Answered the same whether this call queued the job or found one already
      # queued: a second press is one clone.
      {:ok, job} ->
        conn
        |> put_status(:accepted)
        |> put_view(JobJSON)
        |> render(:show, job: Jobs.describe(job))

      {:error, reason} ->
        refusal(reason)
    end
  end

  # Where a branch of this repository is on this machine. Clones or fetches
  # first when it has to, so freshness is a postcondition of being told a path
  # rather than something a caller has to arrange separately.
  #
  # `force` is for a person: it skips the interval that keeps a conversation
  # from re-fetching on every question, which is exactly what somebody who has
  # just pushed, or who has just fixed a credential, is asking for.
  def checkout(conn, %{"project_slug" => project_slug, "id" => id} = params) do
    context = Utils.module(:projects)
    project = context.get_active_project_by_slug!(project_slug)
    project_repo = context.get_project_repo!(project, id)

    opts = [branch: Map.get(params, "branch"), force: params["force"] == true]

    case Utils.module(:workspace).checkout(project, project_repo, opts) do
      {:ok, checkout} -> render(conn, :checkout, checkout: checkout)
      {:error, reason} -> refusal(reason)
    end
  end

  # git's own words are deliberately not passed through here. They are already
  # on the repository as `last_sync_error`, where they survive the request and
  # can be read by whoever is fixing the credential -- and a message composed
  # from a remote's output is not something to render into a response.
  defp refusal(:not_configured), do: {:error, :workspace_not_configured}
  defp refusal({:invalid_branch, branch}), do: {:error, :invalid_branch, %{branch: branch}}
  defp refusal({:unknown_branch, branch}), do: {:error, :unknown_branch, %{branch: branch}}
  defp refusal({:invalid_name, name}), do: {:error, :unusable_repo_name, %{name: name}}
  defp refusal({:root_unavailable, _reason}), do: {:error, :workspace_unwritable}
  defp refusal({:git, _reason}), do: {:error, :repo_unavailable}
  # Oban answering with a changeset. Nothing the caller did.
  defp refusal(%Ecto.Changeset{}), do: {:error, :internal_server_error}

  def delete(conn, %{"project_slug" => project_slug, "id" => id}) do
    context = Utils.module(:projects)
    project = context.get_active_project_by_slug!(project_slug)
    project_repo = context.get_project_repo!(project, id)

    with {:ok, _project_repo} <- context.delete_project_repo(project_repo) do
      send_resp(conn, :no_content, "")
    end
  end
end
