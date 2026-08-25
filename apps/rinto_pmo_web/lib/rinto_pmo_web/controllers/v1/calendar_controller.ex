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
  Records that the person is away on a day.

  Idempotent, and it wins over an imported holiday: being away on a day that
  was already off is not a conflict.
  """
  def put_leave(conn, %{"day" => day} = params) do
    with {:ok, day} <- parse_date("day", day),
         {:ok, calendar_day} <- Calendar.put_leave(day, Map.get(params, "name")) do
      render(conn, :show, day: calendar_day)
    end
  end

  @doc """
  Removes a day of leave.

  Only leave. A holiday is not a person's to delete, and the next import would
  put it back regardless.
  """
  def delete_leave(conn, %{"day" => day}) do
    with {:ok, day} <- parse_date("day", day),
         :ok <- Calendar.delete_leave(day) do
      send_resp(conn, :no_content, "")
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
