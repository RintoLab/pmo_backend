defmodule RintoPMOWeb.V1.CalendarControllerTest do
  use RintoPMOWeb.ConnCase, async: true

  alias RintoPMO.Calendar

  @day ~D[2026-09-09]

  describe "index" do
    test "lists exceptions alongside the years they can be trusted for", %{conn: conn} do
      {:ok, _} = Calendar.import_year(2026, "test", [{~D[2026-10-01], :holiday, "国庆节"}])
      {:ok, _} = Calendar.put_leave(@day, "away")

      body =
        conn
        |> get(~p"/api/v1/calendar/days?from=2026-01-01&to=2026-12-31")
        |> json_response(200)

      assert [
               %{"day" => "2026-09-09", "kind" => "leave", "name" => "away"},
               %{"day" => "2026-10-01", "kind" => "holiday", "name" => "国庆节"}
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
    test "is recorded, and wins over a holiday already on that day", %{conn: conn} do
      {:ok, _} = Calendar.import_year(2026, "test", [{@day, :holiday, "秋分"}])

      assert %{"kind" => "leave", "name" => "away"} =
               conn
               |> put(~p"/api/v1/calendar/days/#{Date.to_iso8601(@day)}/leave", %{
                 "name" => "away"
               })
               |> json_response(200)
               |> Map.fetch!("data")
    end

    test "is removed, but a holiday is not a person's to delete", %{conn: conn} do
      holiday = ~D[2026-10-01]
      {:ok, _} = Calendar.import_year(2026, "test", [{holiday, :holiday, "国庆节"}])
      {:ok, _} = Calendar.put_leave(@day, "away")

      assert conn
             |> delete(~p"/api/v1/calendar/days/#{Date.to_iso8601(@day)}/leave")
             |> response(204)

      assert conn
             |> delete(~p"/api/v1/calendar/days/#{Date.to_iso8601(holiday)}/leave")
             |> response(204)

      assert [%{"day" => "2026-10-01", "kind" => "holiday"}] =
               conn
               |> get(~p"/api/v1/calendar/days?from=2026-01-01&to=2026-12-31")
               |> json_response(200)
               |> Map.fetch!("data")
    end

    test "refuses a day it cannot read", %{conn: conn} do
      assert %{"details" => %{"day" => ["must be an ISO 8601 date"]}} =
               conn
               |> put(~p"/api/v1/calendar/days/someday/leave", %{})
               |> json_response(400)
    end
  end
end
