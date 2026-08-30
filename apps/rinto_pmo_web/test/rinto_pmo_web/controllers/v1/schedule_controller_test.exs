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

    test "a whole day of leave takes a day out the same way a holiday does", %{
      conn: conn,
      week: week,
      monday: monday
    } do
      {:ok, _} = RintoPMO.Calendar.import_year(monday.year, "test", [])
      {:ok, _} = RintoPMO.Calendar.put_leave(monday, 1440, "年假")

      body =
        conn
        |> get(~p"/api/v1/schedule?from=#{Date.to_iso8601(week)}&to=#{Date.to_iso8601(week)}")
        |> json_response(200)

      assert week_of(body, week)["capacity"] == 4 * Calendar.daily_capacity()
    end

    test "two hours of leave takes two hours off the week, not a day", %{
      conn: conn,
      week: week,
      monday: monday
    } do
      {:ok, _} = RintoPMO.Calendar.import_year(monday.year, "test", [])
      {:ok, _} = RintoPMO.Calendar.put_leave(monday, 120, "看医生")

      body =
        conn
        |> get(~p"/api/v1/schedule?from=#{Date.to_iso8601(week)}&to=#{Date.to_iso8601(week)}")
        |> json_response(200)

      assert week_of(body, week)["capacity"] == 5 * Calendar.daily_capacity() - 120
    end

    test "a day's bar is as long as that day, not as long as a workday", %{
      conn: conn,
      week: week,
      monday: monday
    } do
      {:ok, _} = RintoPMO.Calendar.put_leave(monday, 120, "看医生")
      scheduled(60, planned_start_on: monday)

      body =
        conn
        |> get(~p"/api/v1/schedule?from=#{Date.to_iso8601(week)}&to=#{Date.to_iso8601(week)}")
        |> json_response(200)

      assert [%{"day" => day, "capacity" => 360, "allocated" => 60}] =
               week_of(body, week)["days"]

      assert day == Date.to_iso8601(monday)
    end

    test "work that no longer fits the shortened day is reported by name", %{
      conn: conn,
      week: week,
      monday: monday
    } do
      {:ok, _} = RintoPMO.Calendar.import_year(monday.year, "test", [])
      {:ok, _} = RintoPMO.Calendar.put_leave(monday, 120, "看医生")

      # Four days of 480 plus a Monday of 360: the fifth 480 has nowhere to go.
      for _ <- 1..5, do: scheduled(480, planned_start_on: monday, priority: 1)

      body =
        conn
        |> get(~p"/api/v1/schedule?from=#{Date.to_iso8601(week)}&to=#{Date.to_iso8601(week)}")
        |> json_response(200)

      plan = week_of(body, week)

      assert plan["allocated"] == 4 * Calendar.daily_capacity()
      assert length(plan["overflow"]) == 1
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

  describe "history" do
    defp at(%Date{} = day), do: DateTime.new!(day, ~T[09:00:00.000000])

    test "answers what the clocks recorded, with the plan beside it", %{conn: conn} do
      task =
        insert(:task,
          status: :done,
          planned_start_on: ~D[2026-06-08],
          first_planned_on: ~D[2026-05-18],
          started_at: at(~D[2026-06-09]),
          completed_at: at(~D[2026-06-10]),
          estimate_optimistic: 60,
          estimate_likely: 120,
          estimate_pessimistic: 240,
          actual_minutes: 300
        )

      task_id = task.id

      assert [
               %{
                 "task" => %{"id" => ^task_id, "first_planned_on" => "2026-05-18"},
                 "started_on" => "2026-06-09",
                 "completed_on" => "2026-06-10",
                 "planned_on" => "2026-06-08",
                 "first_planned_on" => "2026-05-18",
                 "slip_weeks" => 3,
                 "expected_minutes" => 130,
                 "actual_minutes" => 300
               }
             ] =
               conn
               |> get(~p"/api/v1/history?from=2026-06-08&to=2026-06-14")
               |> json_response(200)
               |> Map.fetch!("data")
    end

    test "defaults to this week so far", %{conn: conn} do
      insert(:task, status: :in_progress, started_at: DateTime.utc_now())

      assert length(conn |> get(~p"/api/v1/history") |> json_response(200) |> Map.fetch!("data")) ==
               1
    end

    # `GET /schedule` refuses to be scoped; this one does not, and the reason
    # the two differ is worth a test rather than a comment alone.
    test "narrows to one project when asked", %{conn: conn} do
      mine = insert(:project)
      here = insert(:task, project: mine, status: :done, started_at: at(~D[2026-06-10]))
      insert(:task, status: :done, started_at: at(~D[2026-06-10]))

      here_id = here.id

      assert [%{"task" => %{"id" => ^here_id}}] =
               conn
               |> get(~p"/api/v1/history?from=2026-06-08&to=2026-06-14&project_id=#{mine.id}")
               |> json_response(200)
               |> Map.fetch!("data")
    end

    test "refuses a date and a project id it cannot read", %{conn: conn} do
      assert %{"details" => %{"from" => ["must be an ISO 8601 date"]}} =
               conn |> get(~p"/api/v1/history?from=last+june") |> json_response(400)

      assert %{"details" => %{"project_id" => ["is invalid"]}} =
               conn |> get(~p"/api/v1/history?project_id=nope") |> json_response(400)
    end
  end
end
