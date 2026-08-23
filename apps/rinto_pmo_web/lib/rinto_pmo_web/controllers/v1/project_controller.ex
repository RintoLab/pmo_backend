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

  def update(conn, %{"slug" => slug}) do
    context = Utils.module(:projects)
    project = context.get_project_by_slug!(slug)

    # Body params only: the path's slug identifies the project rather than
    # being something to write back, and merging it in would look to
    # `Project.update_changeset/2` like a client asking to keep its slug.
    with {:ok, project} <- context.update_project(project, conn.body_params) do
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
