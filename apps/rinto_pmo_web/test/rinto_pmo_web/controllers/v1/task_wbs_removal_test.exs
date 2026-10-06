defmodule RintoPMOWeb.V1.TaskWbsRemovalTest do
  use RintoPMOWeb.ConnCase, async: true

  setup do
    stub_with(RintoPMO.ProjectsMock, RintoPMO.Projects)
    stub_with(RintoPMO.TasksMock, RintoPMO.Tasks)
    :ok
  end

  test "task writes and list routes reject retired hierarchy inputs", %{conn: conn} do
    task = insert(:task)
    project = RintoPMO.Repo.get!(RintoPMO.Projects.Project, task.project_id)

    attrs = %{
      title: "Executable task",
      requirement_id: task.requirement_id,
      repo_id: task.repo_id
    }

    for {field, value} <- [{:kind, "summary"}, {:parent_id, task.id}] do
      body = Map.put(attrs, field, value)

      created =
        conn |> post(~p"/api/v1/projects/#{project.slug}/tasks", body) |> json_response(422)

      assert created["details"][Atom.to_string(field)]

      updated =
        conn |> patch(~p"/api/v1/tasks/#{task.id}", %{field => value}) |> json_response(422)

      assert updated["details"][Atom.to_string(field)]

      for url <- [~p"/api/v1/tasks", ~p"/api/v1/projects/#{project.slug}/tasks"] do
        response = conn |> get(url, %{field => value}) |> json_response(400)
        assert response["details"][Atom.to_string(field)] == ["is no longer supported"]
      end
    end
  end

  test "task responses and write schemas expose only executable task fields", %{conn: conn} do
    task = insert(:task)
    data = conn |> get(~p"/api/v1/tasks/#{task.id}") |> json_response(200) |> Map.fetch!("data")

    for field <-
          ~w(kind parent_id unestimated_tasks unrated_tasks unmeasured_tasks unscheduled_tasks) do
      refute Map.has_key?(data, field)
    end

    schemas = conn |> get(~p"/api/v1/tasks/schema") |> json_response(200) |> Map.fetch!("data")
    assert Enum.sort(Map.keys(schemas)) == ~w(create sync update)

    for shape <- ["create", "update"], field <- ["kind", "parent_id"] do
      refute Map.has_key?(schemas[shape]["properties"], field)
    end
  end

  test "the split route is removed", %{conn: conn} do
    task = insert(:task)

    response = post(conn, "/api/v1/tasks/#{task.id}/split", %{})
    assert response.status == 404
  end
end
