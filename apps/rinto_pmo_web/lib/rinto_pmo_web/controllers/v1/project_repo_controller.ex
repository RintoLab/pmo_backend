defmodule RintoPMOWeb.V1.ProjectRepoController do
  use RintoPMOWeb, :controller

  alias RintoPMO.Utils

  action_fallback RintoPMOWeb.FallbackController

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

  def create(conn, %{"project_slug" => project_slug, "repo" => project_repo_params}) do
    context = Utils.module(:projects)
    project = context.get_active_project_by_slug!(project_slug)

    with {:ok, project_repo} <- context.create_project_repo(project, project_repo_params) do
      conn
      |> put_status(:created)
      |> render(:show, project_repo: project_repo)
    end
  end

  def update(conn, %{
        "project_slug" => project_slug,
        "id" => id,
        "repo" => project_repo_params
      }) do
    context = Utils.module(:projects)
    project = context.get_active_project_by_slug!(project_slug)
    project_repo = context.get_project_repo!(project, id)

    with {:ok, project_repo} <- context.update_project_repo(project_repo, project_repo_params) do
      render(conn, :show, project_repo: project_repo)
    end
  end

  def delete(conn, %{"project_slug" => project_slug, "id" => id}) do
    context = Utils.module(:projects)
    project = context.get_active_project_by_slug!(project_slug)
    project_repo = context.get_project_repo!(project, id)

    with {:ok, _project_repo} <- context.delete_project_repo(project_repo) do
      send_resp(conn, :no_content, "")
    end
  end
end
