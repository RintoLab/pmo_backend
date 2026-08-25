defmodule RintoPMOWeb.V1.ScheduleControllerTest do
  use RintoPMOWeb.ConnCase, async: true

  alias RintoPMO.Calendar

  # Next week, so the assertions do not depend on which day the suite runs:
  # the current week has however many days are left in it.
  setup do
    week = Calendar.next_week(Calendar.current_week())
    %{week: week, monday: week}
  end

  defp scheduled(minutes, attrs) do
    insert(
      :task,
      Keyword.merge(
        [
          estimate_optimistic: minutes,
          estimate_likely: minutes,
          estimate_pessimistic: minutes
        ],
        attrs
      )
    )
  end

  defp week_of(body, week) do
    Enum.find(body["data"], &(&1["week"] == Date.to_iso8601(week)))
  end

  describe "index" do
    test "answers with this week when asked nothing", %{conn: conn} do
      this_week = Date.to_iso8601(Calendar.current_week())

      assert [%{"week" => ^this_week}] =
               conn |> get(~p"/api/v1/schedule") |> json_response(200) |> Map.fetch!("data")
    end

    test "reports a task's share of each day it spans", %{conn: conn, week: week, monday: monday} do
      scheduled(300, planned_start_on: monday, priority: 1)
      spilling = scheduled(300, planned_start_on: monday, priority: 2)
      spilling_id = spilling.id

      body =
        conn
        |> get(~p"/api/v1/schedule?from=#{Date.to_iso8601(week)}&to=#{Date.to_iso8601(week)}")
        |> json_response(200)

      plan = week_of(body, week)

      assert plan["capacity"] == Calendar.week_capacity(Calendar.none(), week)
      assert plan["allocated"] == 600

      [first, second] = plan["days"]
      assert first["allocated"] == Calendar.daily_capacity()
      assert second["allocated"] == 120

      assert %{"minutes" => 180, "task" => %{"id" => ^spilling_id, "priority" => 2}} =
               List.last(first["tasks"])
    end

    test "names what did not fit instead of moving it", %{conn: conn, week: week, monday: monday} do
      for _ <- 1..5, do: scheduled(480, planned_start_on: monday, priority: 1)
      cut = scheduled(60, planned_start_on: monday, priority: 2)
      cut_id = cut.id

      body =
        conn
        |> get(~p"/api/v1/schedule?from=#{Date.to_iso8601(week)}&to=#{Date.to_iso8601(week)}")
        |> json_response(200)

      assert [%{"id" => ^cut_id}] = week_of(body, week)["overflow"]
    end

    test "a backlog task is in no week at all", %{conn: conn, week: week} do
      scheduled(60, planned_start_on: nil)

      body =
        conn
        |> get(~p"/api/v1/schedule?from=#{Date.to_iso8601(week)}&to=#{Date.to_iso8601(week)}")
        |> json_response(200)

      plan = week_of(body, week)
      assert plan["days"] == []
      assert plan["overflow"] == []
    end

    test "says so when the year's holidays were never fetched", %{conn: conn, week: week} do
      body =
        conn
        |> get(~p"/api/v1/schedule?from=#{Date.to_iso8601(week)}&to=#{Date.to_iso8601(week)}")
        |> json_response(200)

      assert week_of(body, week)["calendar_known"] == false
    end

    test "a holiday takes a day out of the week's capacity", %{
      conn: conn,
      week: week,
      monday: monday
    } do
      {:ok, _} = RintoPMO.Calendar.import_year(monday.year, "test", [{monday, :holiday, "假"}])

      body =
        conn
        |> get(~p"/api/v1/schedule?from=#{Date.to_iso8601(week)}&to=#{Date.to_iso8601(week)}")
        |> json_response(200)

      plan = week_of(body, week)

      assert plan["calendar_known"] == true
      assert plan["capacity"] == 4 * Calendar.daily_capacity()
    end

    test "leave takes a day out the same way a holiday does", %{
      conn: conn,
      week: week,
      monday: monday
    } do
      {:ok, _} = RintoPMO.Calendar.import_year(monday.year, "test", [])
      {:ok, _} = RintoPMO.Calendar.put_leave(monday, "away")

      body =
        conn
        |> get(~p"/api/v1/schedule?from=#{Date.to_iso8601(week)}&to=#{Date.to_iso8601(week)}")
        |> json_response(200)

      assert week_of(body, week)["capacity"] == 4 * Calendar.daily_capacity()
    end

    test "refuses a date it cannot read", %{conn: conn} do
      assert %{"details" => %{"from" => ["must be an ISO 8601 date"]}} =
               conn |> get(~p"/api/v1/schedule?from=next+tuesday") |> json_response(400)
    end

    test "refuses a range too far out to mean anything", %{conn: conn} do
      from = Calendar.current_week()
      to = Date.add(from, 7 * 60)

      assert %{"details" => %{"to" => [message]}} =
               conn
               |> get(
                 ~p"/api/v1/schedule?from=#{Date.to_iso8601(from)}&to=#{Date.to_iso8601(to)}"
               )
               |> json_response(400)

      assert message =~ "at most 52 weeks"
    end
  end
end
