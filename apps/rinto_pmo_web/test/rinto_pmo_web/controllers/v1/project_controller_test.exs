defmodule RintoPMOWeb.V1.ProjectControllerTest do
  use RintoPMOWeb.ConnCase, async: true

  alias RintoPMO.Projects.Project
  alias RintoPMO.ProjectsMock

  test "GET /api/v1/projects lists active project summaries", %{conn: conn} do
    project = insert(:project, name: "Rinto PMO")
    project_id = project.id

    expect(ProjectsMock, :list_projects, fn -> [project] end)

    conn = get(conn, ~p"/api/v1/projects")

    assert [%{"id" => ^project_id, "name" => "Rinto PMO", "status" => "active"} = data] =
             json_response(conn, 200)["data"]

    refute Map.has_key?(data, "repos")
  end

  test "GET /api/v1/projects/:slug includes multiple repositories", %{conn: conn} do
    project = insert(:project)
    project_slug = project.slug

    repos = [
      insert(:project_repo, project: project, name: "backend"),
      insert(:project_repo, project: project, name: "frontend")
    ]

    project = %{project | repos: repos}
    project_id = project.id

    expect(ProjectsMock, :get_project_by_slug!, fn ^project_slug -> project end)

    conn = get(conn, ~p"/api/v1/projects/#{project_slug}")

    response = json_response(conn, 200)["data"]
    assert response["id"] == project_id
    assert Enum.map(response["repos"], & &1["name"]) == ["backend", "frontend"]
  end

  test "POST /api/v1/projects creates a project", %{conn: conn} do
    project = insert(:project)
    project_slug = project.slug

    params = %{
      "name" => project.name,
      "slug" => project_slug,
      "description" => project.description
    }

    expect(ProjectsMock, :create_project, fn ^params -> {:ok, project} end)

    conn = post(conn, ~p"/api/v1/projects", project: params)

    assert %{"slug" => ^project_slug, "repos" => []} = json_response(conn, 201)["data"]
  end

  test "PATCH /api/v1/projects/:slug updates project metadata", %{conn: conn} do
    project = insert(:project)
    project_slug = project.slug
    updated = %{project | name: "Updated"}
    params = %{"name" => "Updated"}

    expect(ProjectsMock, :get_project_by_slug!, fn ^project_slug -> project end)
    expect(ProjectsMock, :update_project, fn ^project, ^params -> {:ok, updated} end)

    conn = patch(conn, ~p"/api/v1/projects/#{project_slug}", project: params)

    assert %{"name" => "Updated"} = json_response(conn, 200)["data"]
  end

  test "PUT /api/v1/projects/:slug uses the same update action", %{conn: conn} do
    project = insert(:project)
    project_slug = project.slug
    params = %{"description" => "Updated"}
    updated = %{project | description: "Updated"}

    expect(ProjectsMock, :get_project_by_slug!, fn ^project_slug -> project end)
    expect(ProjectsMock, :update_project, fn ^project, ^params -> {:ok, updated} end)

    conn = put(conn, ~p"/api/v1/projects/#{project_slug}", project: params)

    assert %{"description" => "Updated"} = json_response(conn, 200)["data"]
  end

  test "DELETE /api/v1/projects/:slug archives and returns 204", %{conn: conn} do
    project = insert(:project)
    project_slug = project.slug
    archived = %{project | status: :archived}

    expect(ProjectsMock, :get_project_by_slug!, fn ^project_slug -> project end)
    expect(ProjectsMock, :archive_project, fn ^project -> {:ok, archived} end)

    conn = delete(conn, ~p"/api/v1/projects/#{project_slug}")

    assert response(conn, 204) == ""
  end

  test "POST /api/v1/projects returns validation errors", %{conn: conn} do
    params = %{"name" => "Missing metadata"}
    changeset = Project.changeset(params)

    expect(ProjectsMock, :create_project, fn ^params -> {:error, changeset} end)

    conn = post(conn, ~p"/api/v1/projects", project: params)

    assert %{
             "error" => "validation_error",
             "message" => "Request validation failed.",
             "details" => %{
               "description" => ["can't be blank"],
               "slug" => ["can't be blank"]
             }
           } = json_response(conn, 422)
  end

  test "GET /api/v1/projects/:slug returns 404", %{conn: conn} do
    expect(ProjectsMock, :get_project_by_slug!, fn "missing" ->
      raise Ecto.NoResultsError, queryable: Project
    end)

    assert {404, _headers, body} =
             assert_error_sent(:not_found, fn ->
               get(conn, ~p"/api/v1/projects/missing")
             end)

    assert Jason.decode!(body) == %{
             "error" => "not_found",
             "message" => "The requested resource was not found.",
             "details" => %{}
           }
  end
end
