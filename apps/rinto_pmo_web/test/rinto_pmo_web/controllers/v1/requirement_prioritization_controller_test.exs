defmodule RintoPMOWeb.V1.RequirementPrioritizationControllerTest do
  use RintoPMOWeb.ConnCase, async: true
  alias RintoPMO.AIRoles

  test "starts a single requirement update, polled through the generic jobs endpoint", %{
    conn: conn
  } do
    requirement = insert(:requirement)

    AIRoles.put_role("requirement_prioritization", %{
      "provider" => "google",
      "model" => "flash",
      "thinking_level" => "off"
    })

    result =
      conn
      |> post(~p"/api/v1/requirements/#{requirement.id}/prioritize", %{})
      |> json_response(202)

    assert result["data"]["status"] == "running"
    refute Map.has_key?(result["data"], "suggestions")
    id = result["data"]["id"]
    assert conn |> get(~p"/api/v1/jobs/#{id}") |> json_response(200) == result
  end

  test "reports missing configuration, invalid and missing requirements", %{conn: conn} do
    requirement = insert(:requirement)

    result =
      conn
      |> post(~p"/api/v1/requirements/#{requirement.id}/prioritize", %{})
      |> json_response(422)

    assert result["error"] == "no_prioritization_ai"
    assert conn |> post(~p"/api/v1/requirements/bad/prioritize", %{}) |> json_response(400)

    assert conn
           |> post(~p"/api/v1/requirements/#{Ecto.UUID.generate()}/prioritize", %{})
           |> json_response(404)
  end
end
