defmodule RintoPMOWeb.V1.ScheduleController do
  use RintoPMOWeb, :controller

  alias RintoPMO.Calendar
  alias RintoPMO.Schedule

  # A year. Not a performance limit -- the walk is cheap -- but a limit on how
  # far a forecast is worth reading: every week further out is a projection of
  # a projection, and asking for a hundred of them is a client bug rather than
  # a question.
  @max_weeks 52

  @doc """
  What each week from `from` to `to` holds, and what did not fit.

  Both parameters are dates, and the week each falls in is what is planned.
  `from` defaults to today and `to` to `from`, so the bare endpoint answers
  "this week".

  Weeks earlier than the current one are never returned. The plan is a
  forecast; what already happened is on the tasks themselves.

  This is deliberately not scoped to a project. A week's minutes are shared
  across every project, so a per-project view filters these results rather
  than asking for a project's own schedule -- packing one project alone would
  hand it the whole week and overstate what fits in it.
  """
  def index(conn, params) do
    with {:ok, from} <- date_param(params, "from", Date.utc_today()),
         {:ok, to} <- date_param(params, "to", from),
         :ok <- validate_span(from, to) do
      render(conn, :index, weeks: Schedule.pack(from, to))
    end
  end

  defp date_param(params, name, default) do
    case Map.get(params, name) do
      nil ->
        {:ok, default}

      value ->
        case Date.from_iso8601(value) do
          {:ok, date} -> {:ok, date}
          {:error, _reason} -> {:error, :bad_request, %{name => ["must be an ISO 8601 date"]}}
        end
    end
  end

  defp validate_span(from, to) do
    weeks = Calendar.weeks(Calendar.monday_of(from), Calendar.monday_of(to))

    if length(weeks) > @max_weeks do
      {:error, :bad_request, %{"to" => ["must be at most #{@max_weeks} weeks after from"]}}
    else
      :ok
    end
  end
end
