defmodule RintoPMOWeb.V1.CalendarControllerTest do
  use RintoPMOWeb.ConnCase, async: true

  alias RintoPMO.Calendar

  @day ~D[2026-09-09]

  defp leave_path(day), do: ~p"/api/v1/calendar/days/#{Date.to_iso8601(day)}/leave"

  describe "index" do
    test "lists departures alongside the years they can be trusted for", %{conn: conn} do
      {:ok, _} = Calendar.import_year(2026, "test", [{~D[2026-10-01], :holiday, "国庆节"}])
      {:ok, _} = Calendar.put_leave(@day, 120, "看医生")

      body =
        conn
        |> get(~p"/api/v1/calendar/days?from=2026-01-01&to=2026-12-31")
        |> json_response(200)

      assert [
               %{
                 "day" => "2026-09-09",
                 "kind" => nil,
                 "leave" => %{"minutes" => 120, "name" => "看医生"},
                 "base_capacity_minutes" => 480,
                 "capacity_minutes" => 360
               },
               %{
                 "day" => "2026-10-01",
                 "kind" => "holiday",
                 "name" => "国庆节",
                 "leave" => nil,
                 "capacity_minutes" => 0
               }
             ] = body["data"]

      assert [%{"year" => 2026, "source" => "test"}] = body["imports"]
    end

    test "a year nobody read has no import row, which is the point", %{conn: conn} do
      body =
        conn
        |> get(~p"/api/v1/calendar/days?from=2027-01-01&to=2027-12-31")
        |> json_response(200)

      assert body["data"] == []
      assert body["imports"] == []
    end
  end

  describe "leave" do
    test "takes minutes off the day rather than the whole of it", %{conn: conn} do
      assert %{
               "leave" => %{"minutes" => 120, "name" => "看医生"},
               "base_capacity_minutes" => 480,
               "capacity_minutes" => 360
             } =
               conn
               |> put(leave_path(@day), %{"minutes" => 120, "name" => "看医生"})
               |> json_response(200)
               |> Map.fetch!("data")
    end

    test "1440 is a whole day, and leaves nothing", %{conn: conn} do
      assert %{"leave" => %{"minutes" => 1440}, "capacity_minutes" => 0} =
               conn
               |> put(leave_path(@day), %{"minutes" => 1440, "name" => "年假"})
               |> json_response(200)
               |> Map.fetch!("data")
    end

    test "records against a holiday without overwriting it", %{conn: conn} do
      {:ok, _} = Calendar.import_year(2026, "test", [{@day, :holiday, "秋分"}])

      assert %{
               "kind" => "holiday",
               "name" => "秋分",
               "leave" => %{"minutes" => 120},
               "base_capacity_minutes" => 0,
               "capacity_minutes" => 0
             } =
               conn
               |> put(leave_path(@day), %{"minutes" => 120, "name" => "看医生"})
               |> json_response(200)
               |> Map.fetch!("data")
    end

    test "a make-up Saturday gets its minutes back when the leave goes", %{conn: conn} do
      saturday = ~D[2026-09-12]
      {:ok, _} = Calendar.import_year(2026, "test", [{saturday, :workday, "调休"}])

      assert conn
             |> put(leave_path(saturday), %{"minutes" => 1440})
             |> json_response(200)
             |> get_in(["data", "capacity_minutes"]) == 0

      assert conn |> delete(leave_path(saturday)) |> response(204)

      assert [%{"day" => "2026-09-12", "kind" => "workday", "capacity_minutes" => 480}] =
               conn
               |> get(~p"/api/v1/calendar/days?from=2026-01-01&to=2026-12-31")
               |> json_response(200)
               |> Map.fetch!("data")
    end

    test "is removed, and a holiday is not a person's to delete", %{conn: conn} do
      holiday = ~D[2026-10-01]
      {:ok, _} = Calendar.import_year(2026, "test", [{holiday, :holiday, "国庆节"}])
      {:ok, _} = Calendar.put_leave(@day, 120, "看医生")

      assert conn |> delete(leave_path(@day)) |> response(204)
      assert conn |> delete(leave_path(holiday)) |> response(204)

      assert [%{"day" => "2026-10-01", "kind" => "holiday"}] =
               conn
               |> get(~p"/api/v1/calendar/days?from=2026-01-01&to=2026-12-31")
               |> json_response(200)
               |> Map.fetch!("data")
    end

    test "refuses leave with no duration", %{conn: conn} do
      assert %{"details" => %{"minutes" => [_message]}} =
               conn |> put(leave_path(@day), %{"name" => "看医生"}) |> json_response(400)

      assert %{"details" => %{"minutes" => [_message]}} =
               conn |> put(leave_path(@day), %{"minutes" => 0}) |> json_response(400)
    end

    # No ceiling on purpose: whether a number covers the whole day is a
    # comparison made when capacity is asked, not a rule frozen into the row.
    test "accepts more minutes than the day holds", %{conn: conn} do
      assert %{"leave" => %{"minutes" => 5000}, "capacity_minutes" => 0} =
               conn
               |> put(leave_path(@day), %{"minutes" => 5000})
               |> json_response(200)
               |> Map.fetch!("data")
    end

    test "refuses a day it cannot read", %{conn: conn} do
      assert %{"details" => %{"day" => ["must be an ISO 8601 date"]}} =
               conn
               |> put(~p"/api/v1/calendar/days/someday/leave", %{"minutes" => 120})
               |> json_response(400)
    end
  end
end
