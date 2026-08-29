defmodule RintoPMOWeb.V1.ProjectRepoControllerTest do
  use RintoPMOWeb.ConnCase, async: true

  alias RintoPMO.Projects.ProjectRepo
  alias RintoPMO.ProjectsMock
  alias RintoPMO.WorkspaceMock

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
      "credential_id" => credential_id
    }

    expect(ProjectsMock, :create_project_repo, fn ^project, ^params ->
      {:ok, project_repo}
    end)

    conn = post(conn, ~p"/api/v1/projects/#{project.slug}/repos", params)

    assert %{"name" => "backend", "credential_id" => ^credential_id} =
             json_response(conn, 201)["data"]
  end

  # The URL is the only thing the caller has to know. The name is derived from
  # it, and there is no branch to send: which one to read is decided per
  # checkout, not per registration.
  test "POST /api/v1/projects/:slug/repos takes only a git URL", %{conn: conn} do
    project = expect_project()
    project_repo = insert(:project_repo, project: project, name: "backend")
    params = %{"git_url" => "https://example.com/acme/backend.git"}

    expect(ProjectsMock, :create_project_repo, fn ^project, ^params ->
      {:ok, project_repo}
    end)

    conn = post(conn, ~p"/api/v1/projects/#{project.slug}/repos", params)

    assert %{"name" => "backend"} = data = json_response(conn, 201)["data"]
    refute Map.has_key?(data, "branch")
  end

  test "PATCH /api/v1/projects/:slug/repos/:id updates a repository", %{conn: conn} do
    project = expect_project()

    project_repo = insert(:project_repo, project: project, name: "backend")

    updated = %{project_repo | name: "next"}
    params = %{"name" => "next"}

    expect(ProjectsMock, :get_project_repo!, fn ^project, id ->
      assert id == project_repo.id
      project_repo
    end)

    expect(ProjectsMock, :update_project_repo, fn ^project_repo, ^params ->
      {:ok, updated}
    end)

    conn =
      patch(conn, ~p"/api/v1/projects/#{project.slug}/repos/#{project_repo.id}", params)

    assert %{"name" => "next"} = json_response(conn, 200)["data"]
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
             "details" => %{"git_url" => ["can't be blank"]}
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

  describe "POST /api/v1/projects/:slug/repos/:id/checkout" do
    test "answers where a branch is and how current it is", %{conn: conn} do
      %{project: project, repo: repo} = expect_repo()

      expect(WorkspaceMock, :checkout, fn ^project, ^repo, opts ->
        assert opts[:branch] == nil
        assert opts[:force] == false

        {:ok,
         %{
           path: "/srv/workspace/acme/backend/worktrees/main",
           branch: "main",
           commit: "1a2b3c4d",
           synced_at: ~U[2026-08-29 10:00:00.000000Z],
           sync_error: nil
         }}
      end)

      conn = post(conn, ~p"/api/v1/projects/#{project.slug}/repos/#{repo.id}/checkout")

      assert %{
               "path" => "/srv/workspace/acme/backend/worktrees/main",
               "branch" => "main",
               "commit" => "1a2b3c4d",
               "sync_error" => nil
             } = json_response(conn, 200)["data"]
    end

    test "passes on the branch and the force asked for", %{conn: conn} do
      %{project: project, repo: repo} = expect_repo()

      expect(WorkspaceMock, :checkout, fn ^project, ^repo, opts ->
        assert opts[:branch] == "feat/x"
        assert opts[:force] == true

        {:ok, checkout(branch: "feat/x")}
      end)

      conn =
        post(conn, ~p"/api/v1/projects/#{project.slug}/repos/#{repo.id}/checkout", %{
          "branch" => "feat/x",
          "force" => true
        })

      assert %{"branch" => "feat/x"} = json_response(conn, 200)["data"]
    end

    test "hands back a stale copy with the reason it is stale", %{conn: conn} do
      %{project: project, repo: repo} = expect_repo()

      expect(WorkspaceMock, :checkout, fn _project, _repo, _opts ->
        {:ok, checkout(sync_error: "git fetch failed (exit 128): could not read from remote")}
      end)

      conn = post(conn, ~p"/api/v1/projects/#{project.slug}/repos/#{repo.id}/checkout")

      assert %{"sync_error" => "git fetch failed" <> _rest} = json_response(conn, 200)["data"]
    end

    test "says so when this server keeps no working copies", %{conn: conn} do
      %{project: project, repo: repo} = expect_repo()

      expect(WorkspaceMock, :checkout, fn _project, _repo, _opts -> {:error, :not_configured} end)

      conn = post(conn, ~p"/api/v1/projects/#{project.slug}/repos/#{repo.id}/checkout")

      assert %{"error" => "workspace_not_configured"} = json_response(conn, 503)
    end

    test "names the branch it was asked for when there is no such branch", %{conn: conn} do
      %{project: project, repo: repo} = expect_repo()

      expect(WorkspaceMock, :checkout, fn _project, _repo, _opts ->
        {:error, {:unknown_branch, "nope"}}
      end)

      conn =
        post(conn, ~p"/api/v1/projects/#{project.slug}/repos/#{repo.id}/checkout", %{
          "branch" => "nope"
        })

      assert %{"error" => "unknown_branch", "details" => %{"branch" => "nope"}} =
               json_response(conn, 422)
    end

    test "says so when neither the repository nor its remote names a branch", %{conn: conn} do
      %{project: project, repo: repo} = expect_repo()

      expect(WorkspaceMock, :checkout, fn _project, _repo, _opts ->
        {:error, :no_default_branch}
      end)

      conn = post(conn, ~p"/api/v1/projects/#{project.slug}/repos/#{repo.id}/checkout")

      assert %{"error" => "no_default_branch"} = json_response(conn, 422)
    end

    test "refuses a branch name git would not take", %{conn: conn} do
      %{project: project, repo: repo} = expect_repo()

      expect(WorkspaceMock, :checkout, fn _project, _repo, _opts ->
        {:error, {:invalid_branch, "--upload-pack=touch"}}
      end)

      conn =
        post(conn, ~p"/api/v1/projects/#{project.slug}/repos/#{repo.id}/checkout", %{
          "branch" => "--upload-pack=touch"
        })

      assert %{"error" => "invalid_branch", "details" => %{"branch" => "--upload-pack=touch"}} =
               json_response(conn, 422)
    end

    test "keeps git's own words out of the response", %{conn: conn} do
      %{project: project, repo: repo} = expect_repo()

      expect(WorkspaceMock, :checkout, fn _project, _repo, _opts ->
        {:error,
         {:git,
          {:git,
           %{
             argv: ["clone"],
             status: {:exit, 128},
             output: "Authentication failed for https://git-bot@example.com"
           }}}}
      end)

      conn = post(conn, ~p"/api/v1/projects/#{project.slug}/repos/#{repo.id}/checkout")

      body = json_response(conn, 503)
      assert %{"error" => "repo_unavailable"} = body
      refute inspect(body) =~ "git-bot"
    end
  end

  describe "POST /api/v1/projects/:slug/repos/:id/sync" do
    test "queues the work and answers with the job", %{conn: conn} do
      %{project: project, repo: repo} = expect_repo()

      expect(WorkspaceMock, :request_sync, fn ^repo ->
        {:ok, queued_job(repo)}
      end)

      conn = post(conn, ~p"/api/v1/projects/#{project.slug}/repos/#{repo.id}/sync")

      assert %{"id" => 42, "worker" => "RintoPMO.Workspace.SyncWorker", "status" => "running"} =
               json_response(conn, 202)["data"]
    end

    test "says so when this server keeps no working copies", %{conn: conn} do
      %{project: project, repo: repo} = expect_repo()

      expect(WorkspaceMock, :request_sync, fn _repo -> {:error, :not_configured} end)

      conn = post(conn, ~p"/api/v1/projects/#{project.slug}/repos/#{repo.id}/sync")

      assert %{"error" => "workspace_not_configured"} = json_response(conn, 503)
    end
  end

  # Built rather than inserted: the controller only reads it, and Oban's queues
  # are off in test so nothing would run it anyway.
  defp queued_job(repo) do
    %Oban.Job{
      id: 42,
      worker: "RintoPMO.Workspace.SyncWorker",
      queue: "default",
      state: "available",
      args: %{"project_repo_id" => repo.id},
      errors: [],
      priority: 0,
      inserted_at: ~U[2026-08-29 10:00:00.000000Z],
      scheduled_at: ~U[2026-08-29 10:00:00.000000Z]
    }
  end

  defp checkout(overrides) do
    Enum.into(overrides, %{
      path: "/srv/workspace/acme/backend/worktrees/main",
      branch: "main",
      commit: "1a2b3c4d",
      synced_at: ~U[2026-08-29 10:00:00.000000Z],
      sync_error: nil
    })
  end

  defp expect_repo do
    project = expect_project()
    repo = insert(:project_repo, project: project, name: "backend")

    expect(ProjectsMock, :get_project_repo!, fn ^project, id ->
      assert id == repo.id
      repo
    end)

    %{project: project, repo: repo}
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
