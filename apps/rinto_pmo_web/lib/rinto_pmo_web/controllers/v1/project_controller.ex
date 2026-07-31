defmodule RintoPMOWeb.V1.ProjectController do
  use RintoPMOWeb, :controller

  alias RintoPMO.Utils

  def index(conn, _params) do
    projects = Utils.module(:projects).list_projects()

    render(conn, :index, projects: projects)
  end

  def show(conn, %{"slug" => slug}) do
    project = Utils.module(:projects).get_project_by_slug!(slug)

    render(conn, :show, project: project)
  end

  def create(conn, params) do
    with {:ok, project} <- Utils.module(:projects).create_project(params) do
      conn
      |> put_status(:created)
      |> render(:show, project: project)
    end
  end

  def update(conn, %{"slug" => slug} = params) do
    context = Utils.module(:projects)
    project = context.get_project_by_slug!(slug)
    project_params = Map.delete(params, "slug")

    with {:ok, project} <- context.update_project(project, project_params) do
      render(conn, :show, project: project)
    end
  end

  def delete(conn, %{"slug" => slug}) do
    context = Utils.module(:projects)
    project = context.get_project_by_slug!(slug)

    with {:ok, _project} <- context.archive_project(project) do
      send_resp(conn, :no_content, "")
    end
  end
end
