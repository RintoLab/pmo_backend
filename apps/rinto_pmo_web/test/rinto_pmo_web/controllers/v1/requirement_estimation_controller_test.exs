defmodule RintoPMOWeb.V1.RequirementEstimationControllerTest do
  use RintoPMOWeb.ConnCase, async: true

  alias RintoPMO.AIRoles

  test "returns workload in lists and details, and explains an unplanned skip", %{conn: conn} do
    requirement = insert(:requirement)
    detail = conn |> get(~p"/api/v1/requirements/#{requirement.id}") |> json_response(200)
    assert detail["data"]["workload"]["estimate"]["total"] == nil
    assert detail["data"]["workload"]["unplanned_requirement_count"] == 1
    list = conn |> get(~p"/api/v1/requirements") |> json_response(200)
    assert hd(list["data"])["workload"] == detail["data"]["workload"]

    result =
      conn
      |> post(~p"/api/v1/requirements/estimate", %{requirement_ids: [requirement.id]})
      |> json_response(200)

    assert [%{"reason" => "no_tasks", "job" => nil}] = result["data"]
  end

  test "starts a job with the public polling contract and returns the existing job on repeat", %{
    conn: conn
  } do
    # Even a task with a complete time estimate needs a job for missing difficulty.
    task = insert(:task, estimate_optimistic: 10, estimate_likely: 20, estimate_pessimistic: 30)

    assert {:ok, _} =
             AIRoles.put_role("task_estimation", %{
               "provider" => "google",
               "model" => "flash",
               "thinking_level" => "off"
             })

    params = %{requirement_ids: [task.requirement_id]}
    first = conn |> post(~p"/api/v1/requirements/estimate", params) |> json_response(202)
    second = conn |> post(~p"/api/v1/requirements/estimate", params) |> json_response(202)
    assert first == second
    job = hd(first["data"])["job"]
    assert job["status"] == "running"
    polled = conn |> get(~p"/api/v1/jobs/#{job["id"]}") |> json_response(200)
    assert polled["data"] == job
  end

  test "validates batch input and configured AI role", %{conn: conn} do
    task = insert(:task)
    invalid = conn |> post(~p"/api/v1/requirements/estimate", %{}) |> json_response(400)
    assert invalid["error"] == "bad_request"

    missing =
      conn
      |> post(~p"/api/v1/requirements/estimate", %{requirement_ids: [task.requirement_id]})
      |> json_response(422)

    assert missing["error"] == "no_estimation_ai"
  end
end
