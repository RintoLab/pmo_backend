defmodule RintoPMOWeb.V1.RequirementController do
  use RintoPMOWeb, :controller

  alias RintoPMO.Projects
  alias RintoPMO.Requirements

  def index(conn, %{"project_slug" => slug}) do
    project = Projects.get_project_by_slug!(slug)
    render(conn, :index, requirements: Requirements.list_requirements(project))
  end

  def show(conn, %{"project_slug" => slug, "id" => id}) do
    project = Projects.get_project_by_slug!(slug)
    render(conn, :show, requirement: Requirements.get_requirement!(project, id))
  end

  def create(conn, %{"project_slug" => slug}) do
    project = Projects.get_project_by_slug!(slug)

    with {:ok, requirement} <- Requirements.create_requirement(project, conn.body_params) do
      conn
      |> put_status(:created)
      |> render(:show, requirement: requirement)
    end
  end

  def update(conn, %{"project_slug" => slug, "id" => id}) do
    project = Projects.get_project_by_slug!(slug)
    requirement = Requirements.get_requirement!(project, id)

    with {:ok, requirement} <- Requirements.update_requirement(requirement, conn.body_params) do
      render(conn, :show, requirement: requirement)
    end
  end

  def delete(conn, %{"project_slug" => slug, "id" => id}) do
    project = Projects.get_project_by_slug!(slug)
    requirement = Requirements.get_requirement!(project, id)

    with {:ok, _requirement} <- Requirements.archive_requirement(requirement) do
      send_resp(conn, :no_content, "")
    end
  end
end
