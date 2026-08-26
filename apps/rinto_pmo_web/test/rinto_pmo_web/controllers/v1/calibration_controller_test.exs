defmodule RintoPMOWeb.V1.CalibrationControllerTest do
  use RintoPMOWeb.ConnCase, async: true

  defp at(%Date{} = day), do: DateTime.new!(day, ~T[17:00:00.000000])

  defp finished(attrs) do
    insert(:task, Keyword.merge([status: :done, completed_at: at(~D[2026-06-10])], attrs))
  end

  describe "index" do
    test "answers both groupings in one response", %{conn: conn} do
      finished(
        difficulty: 5,
        actual_minutes: 180,
        estimate_optimistic: 60,
        estimate_likely: 120,
        estimate_pessimistic: 240
      )

      body =
        conn
        |> get(~p"/api/v1/calibration?from=2026-06-08&to=2026-06-14")
        |> json_response(200)
        |> Map.fetch!("data")

      assert [
               %{
                 "week" => "2026-06-08",
                 "completed" => 1,
                 "comparable" => 1,
                 "expected_minutes" => 130,
                 "actual_minutes" => 180,
                 "unestimated" => 0,
                 "unmeasured" => 0
               }
             ] = body["weeks"]

      assert %{"difficulty" => 5, "tasks" => 1, "measured" => 1, "median_actual_minutes" => 180} =
               Enum.find(body["difficulty"], &(&1["difficulty"] == 5))

      assert length(body["difficulty"]) == 7
    end

    test "defaults to the last twelve weeks", %{conn: conn} do
      body = conn |> get(~p"/api/v1/calibration") |> json_response(200) |> Map.fetch!("data")

      assert length(body["weeks"]) in [12, 13]
    end

    test "narrows to one project when asked", %{conn: conn} do
      mine = insert(:project)
      finished(project: mine, actual_minutes: 60)
      finished(actual_minutes: 999)

      body =
        conn
        |> get(~p"/api/v1/calibration?from=2026-06-08&to=2026-06-14&project_id=#{mine.id}")
        |> json_response(200)
        |> Map.fetch!("data")

      assert [%{"completed" => 1}] = body["weeks"]
    end

    test "refuses what it cannot read, and a window that runs backwards", %{conn: conn} do
      assert %{"details" => %{"from" => ["must be an ISO 8601 date"]}} =
               conn |> get(~p"/api/v1/calibration?from=june") |> json_response(400)

      assert %{"details" => %{"project_id" => ["is invalid"]}} =
               conn |> get(~p"/api/v1/calibration?project_id=nope") |> json_response(400)

      assert %{"details" => %{"from" => ["must not be after to"]}} =
               conn
               |> get(~p"/api/v1/calibration?from=2026-06-14&to=2026-06-08")
               |> json_response(400)

      assert %{"details" => %{"to" => [message]}} =
               conn
               |> get(~p"/api/v1/calibration?from=2020-01-01&to=2026-06-08")
               |> json_response(400)

      assert message =~ "at most 104 weeks"
    end
  end
end
