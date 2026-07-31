defmodule RintoPMOWeb.V1.ProjectRepoControllerTest do
  use RintoPMOWeb.ConnCase, async: true

  alias RintoPMO.Projects.ProjectRepo
  alias RintoPMO.ProjectsMock

  test "GET /api/v1/projects/:slug/repos lists repositories", %{conn: conn} do
    project = expect_project()
    project_repo = insert(:project_repo, project: project)
    project_repo_id = project_repo.id

    expect(ProjectsMock, :list_project_repos, fn ^project -> [project_repo] end)

    conn = get(conn, ~p"/api/v1/projects/#{project.slug}/repos")

    assert [%{"id" => ^project_repo_id}] = json_response(conn, 200)["data"]
  end

  test "GET /api/v1/projects/:slug/repos/:id shows a scoped repository", %{conn: conn} do
    project = expect_project()
    project_repo = insert(:project_repo, project: project)
    project_repo_id = project_repo.id

    expect(ProjectsMock, :get_project_repo!, fn ^project, id ->
      assert id == project_repo.id
      project_repo
    end)

    conn = get(conn, ~p"/api/v1/projects/#{project.slug}/repos/#{project_repo.id}")

    assert %{"id" => ^project_repo_id, "credential_id" => nil} =
             json_response(conn, 200)["data"]
  end

  test "POST /api/v1/projects/:slug/repos creates a repository", %{conn: conn} do
    project = expect_project()
    credential = insert(:repo_credential)
    credential_id = credential.id

    project_repo =
      insert(:project_repo, project: project, credential: credential, name: "backend")

    params = %{
      "name" => "backend",
      "git_url" => "https://example.com/backend.git",
      "branch" => "main",
      "credential_id" => credential_id
    }

    expect(ProjectsMock, :create_project_repo, fn ^project, ^params ->
      {:ok, project_repo}
    end)

    conn = post(conn, ~p"/api/v1/projects/#{project.slug}/repos", params)

    assert %{"name" => "backend", "credential_id" => ^credential_id} =
             json_response(conn, 201)["data"]
  end

  test "PATCH /api/v1/projects/:slug/repos/:id updates a repository", %{conn: conn} do
    project = expect_project()

    project_repo = insert(:project_repo, project: project, branch: "main")

    updated = %{project_repo | branch: "next"}
    params = %{"branch" => "next"}

    expect(ProjectsMock, :get_project_repo!, fn ^project, id ->
      assert id == project_repo.id
      project_repo
    end)

    expect(ProjectsMock, :update_project_repo, fn ^project_repo, ^params ->
      {:ok, updated}
    end)

    conn =
      patch(conn, ~p"/api/v1/projects/#{project.slug}/repos/#{project_repo.id}", params)

    assert %{"branch" => "next"} = json_response(conn, 200)["data"]
  end

  test "DELETE /api/v1/projects/:slug/repos/:id returns 204", %{conn: conn} do
    project = expect_project()
    project_repo = insert(:project_repo, project: project)

    expect(ProjectsMock, :get_project_repo!, fn ^project, id ->
      assert id == project_repo.id
      project_repo
    end)

    expect(ProjectsMock, :delete_project_repo, fn ^project_repo ->
      {:ok, project_repo}
    end)

    conn = delete(conn, ~p"/api/v1/projects/#{project.slug}/repos/#{project_repo.id}")

    assert response(conn, 204) == ""
  end

  test "POST /api/v1/projects/:slug/repos returns validation errors", %{conn: conn} do
    project = expect_project()
    params = %{"name" => "backend"}
    changeset = ProjectRepo.changeset(%ProjectRepo{}, params)

    expect(ProjectsMock, :create_project_repo, fn ^project, ^params ->
      {:error, changeset}
    end)

    conn = post(conn, ~p"/api/v1/projects/#{project.slug}/repos", params)

    assert %{
             "error" => "validation_error",
             "message" => "Request validation failed.",
             "details" => %{
               "branch" => ["can't be blank"],
               "git_url" => ["can't be blank"]
             }
           } = json_response(conn, 422)
  end

  test "GET /api/v1/projects/:slug/repos/:id returns 404 for an invalid scope", %{conn: conn} do
    project = expect_project()
    project_repo = insert(:project_repo)
    id = project_repo.id

    expect(ProjectsMock, :get_project_repo!, fn ^project, ^id ->
      raise Ecto.NoResultsError, queryable: ProjectRepo
    end)

    assert {404, _headers, _body} =
             assert_error_sent(:not_found, fn ->
               get(conn, ~p"/api/v1/projects/#{project.slug}/repos/#{id}")
             end)
  end

  defp expect_project do
    project = insert(:project)

    expect(ProjectsMock, :get_active_project_by_slug!, fn slug ->
      assert slug == project.slug
      project
    end)

    project
  end
end
