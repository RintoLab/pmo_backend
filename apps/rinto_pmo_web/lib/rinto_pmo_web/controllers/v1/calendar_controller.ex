defmodule RintoPMOWeb.V1.CalendarController do
  use RintoPMOWeb, :controller

  alias RintoPMO.Calendar

  @doc """
  Every day between `from` and `to` that is not what the weekend rule says.

  Holidays and make-up days come from the importer; leave comes from here.
  """
  def index(conn, params) do
    with {:ok, from} <- date_param(params, "from", Date.utc_today()),
         {:ok, to} <- date_param(params, "to", Date.add(from, 365)) do
      render(conn, :index, days: Calendar.list_days(from, to), imports: Calendar.list_imports())
    end
  end

  @doc """
  Records how many minutes of a day the person is away for.

  Idempotent on the date -- a correction replaces rather than adds -- and it
  does not touch the calendar underneath: being away on a day that was already
  off is recorded and simply subtracts from nothing.

  `minutes` has no ceiling, deliberately. Whether a number covers the whole day
  is decided by comparing it against what the day holds, every time capacity is
  asked, rather than being fixed when the row was written. A whole day off is
  1440 by convention, which stays a whole day whatever the daily capacity
  becomes.
  """
  def put_leave(conn, %{"day" => day} = params) do
    with {:ok, day} <- parse_date("day", day),
         {:ok, minutes} <- minutes_param(params),
         {:ok, _leave} <- Calendar.put_leave(day, minutes, Map.get(params, "name")) do
      render(conn, :show, day: Calendar.get_day(day))
    end
  end

  @doc """
  Removes a day of leave.

  Only leave -- a holiday is in another table and out of reach. The day goes
  back to whatever the announcement says about it, which is the whole point of
  their being two tables.
  """
  def delete_leave(conn, %{"day" => day}) do
    with {:ok, day} <- parse_date("day", day),
         :ok <- Calendar.delete_leave(day) do
      send_resp(conn, :no_content, "")
    end
  end

  # A whole number of minutes, and required: leave with no duration is not
  # leave. The upper bound is absent on purpose -- see `put_leave/2`.
  defp minutes_param(params) do
    case Map.get(params, "minutes") do
      minutes when is_integer(minutes) and minutes > 0 ->
        {:ok, minutes}

      _otherwise ->
        {:error, :bad_request, %{"minutes" => ["must be a whole number of minutes above zero"]}}
    end
  end

  defp date_param(params, name, default) do
    case Map.get(params, name) do
      nil -> {:ok, default}
      value -> parse_date(name, value)
    end
  end

  defp parse_date(name, value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> {:ok, date}
      {:error, _reason} -> {:error, :bad_request, %{name => ["must be an ISO 8601 date"]}}
    end
  end
end
