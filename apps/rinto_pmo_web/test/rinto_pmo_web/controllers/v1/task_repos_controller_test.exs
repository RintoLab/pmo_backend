defmodule RintoPMOWeb.V1.TaskReposControllerTest do
  use RintoPMOWeb.ConnCase, async: true

  setup do
    stub_with(RintoPMO.ProjectsMock, RintoPMO.Projects)
    stub_with(RintoPMO.TasksMock, RintoPMO.Tasks)
    :ok
  end

  test "API carries repository ownership through writes, reads and both list routes", %{
    conn: conn
  } do
    project = insert(:project)
    requirement = insert(:requirement, project: project)
    first = insert(:project_repo, project: project)
    second = insert(:project_repo, project: project)
    attrs = %{title: "Work", requirement_id: requirement.id, repo_id: first.id}

    created =
      conn |> post(~p"/api/v1/projects/#{project.slug}/tasks", attrs) |> json_response(201)

    task_id = created["data"]["id"]
    assert created["data"]["repo_id"] == first.id

    read = conn |> get(~p"/api/v1/tasks/#{task_id}") |> json_response(200)
    assert read["data"]["repo_id"] == first.id

    updated =
      conn |> patch(~p"/api/v1/tasks/#{task_id}", %{repo_id: second.id}) |> json_response(200)

    assert updated["data"]["repo_id"] == second.id

    for url <- [~p"/api/v1/tasks", ~p"/api/v1/projects/#{project.slug}/tasks"] do
      assert %{"data" => []} = conn |> get(url, %{repo_id: first.id}) |> json_response(200)

      assert %{"data" => [%{"id" => ^task_id}]} =
               conn |> get(url, %{repo_id: second.id}) |> json_response(200)

      assert %{"details" => %{"repo_id" => ["is invalid"]}} =
               conn |> get(url, %{repo_id: "bad"}) |> json_response(400)
    end
  end

  test "missing and foreign repositories are field errors, not silently ignored", %{conn: conn} do
    project = insert(:project)
    requirement = insert(:requirement, project: project)
    foreign = insert(:project_repo)
    attrs = %{title: "Work", requirement_id: requirement.id}

    for body <- [attrs, Map.put(attrs, :repo_id, foreign.id)] do
      result =
        conn |> post(~p"/api/v1/projects/#{project.slug}/tasks", body) |> json_response(422)

      assert result["details"]["repo_id"]
    end
  end
end
