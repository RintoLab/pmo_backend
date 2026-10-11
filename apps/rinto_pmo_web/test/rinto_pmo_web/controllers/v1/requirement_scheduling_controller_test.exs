defmodule RintoPMOWeb.V1.RequirementSchedulingControllerTest do
  use RintoPMOWeb.ConnCase, async: true

  alias RintoPMO.Repo
  alias RintoPMO.Tasks

  setup do
    project = insert(:project)
    requirement = insert(:requirement, project: project, priority: 2)
    %{project: project, requirement: requirement}
  end

  test "returns updated task representations and skip reasons, and retries preserve dates", %{
    conn: conn,
    project: project,
    requirement: requirement
  } do
    task = insert(:task, project: project, requirement: requirement)
    done = insert(:task, project: project, requirement: requirement, status: :done)
    path = ~p"/api/v1/requirements/#{requirement.id}/schedule"
    response = conn |> post(path, %{planned_start_on: "2026-10-14"}) |> json_response(200)
    data = response["data"]
    assert data["requirement_id"] == requirement.id
    assert data["planned_start_on"] == "2026-10-14"
    assert [updated] = data["tasks"]
    assert updated["id"] == task.id
    assert updated["priority"] == 2
    assert updated["planned_start_on"] == "2026-10-14"
    assert updated["first_planned_on"] == "2026-10-14"
    assert data["skipped"] == [%{"task_id" => done.id, "reason" => "not_live"}]

    retry = conn |> post(path, %{planned_start_on: "2026-10-21"}) |> json_response(200)
    assert retry["data"]["tasks"] == []
    assert %{"task_id" => task.id, "reason" => "already_scheduled"} in retry["data"]["skipped"]
    assert Repo.reload!(task).planned_start_on == ~D[2026-10-14]
  end

  test "rejects missing, null, malformed dates and unsupported fields", %{
    conn: conn,
    requirement: requirement
  } do
    path = ~p"/api/v1/requirements/#{requirement.id}/schedule"

    for input <- [
          %{},
          %{planned_start_on: nil},
          %{planned_start_on: "2026-02-30"},
          %{planned_start_on: "not-a-date"},
          %{planned_start_on: 123},
          %{planned_start_on: %{}},
          %{planned_start_on: ["2026-10-14"]},
          %{planned_start_on: "2026-10-14", task_ids: []}
        ] do
      response = conn |> post(path, input) |> json_response(400)
      assert response["details"]["planned_start_on"]
    end
  end

  test "returns 400 for invalid ids and 404 for missing requirements", %{conn: conn} do
    for {id, status} <- [{"invalid", 400}, {UUIDv7.generate(), 404}] do
      assert conn
             |> post(~p"/api/v1/requirements/#{id}/schedule", %{planned_start_on: "2026-10-14"})
             |> json_response(status)
    end
  end

  test "returns existing dependency errors and rolls back every task", %{
    conn: conn,
    project: project,
    requirement: requirement
  } do
    independent = insert(:task, project: project, requirement: requirement)
    waiting = insert(:task, project: project, requirement: requirement)
    external = insert(:task)
    assert {:ok, _} = Tasks.add_dependency(waiting, external.id)

    response =
      conn
      |> post(~p"/api/v1/requirements/#{requirement.id}/schedule", %{
        planned_start_on: "2026-10-14"
      })
      |> json_response(422)

    assert response["error"] == "dependency_out_of_order"
    assert response["details"]["task_id"] == waiting.id
    assert response["details"]["depends_on_id"] == external.id
    assert response["details"]["planned_start_on"] == "2026-10-14"
    assert Repo.reload!(independent).planned_start_on == nil
    assert Repo.reload!(waiting).planned_start_on == nil
  end
end
