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

  @doc """
  What was actually worked between `from` and `to`.

  The counterpart to `index/2`, and deliberately a separate endpoint rather
  than a flag on it: one is a forecast the packer computes, the other is what
  the clocks recorded, and a client that could ask for "both" would get one
  shape carrying two kinds of claim.

  `from` defaults to the Monday of the current week and `to` to today, so the
  bare endpoint answers "what has happened this week so far".

  Scoped to a project when `project_id` is given, which `index/2` refuses to
  be. The refusal there is about arithmetic -- packing one project alone would
  hand it the whole week -- and nothing about the past is computed that way.
  A record is a record whichever project it belongs to.
  """
  def history(conn, params) do
    with {:ok, from} <- date_param(params, "from", Calendar.current_week()),
         {:ok, to} <- date_param(params, "to", Date.utc_today()),
         {:ok, project_id} <- project_param(params) do
      render(conn, :history, records: Schedule.history(from, to, project_id))
    end
  end

  defp project_param(params) do
    case Map.get(params, "project_id") do
      nil ->
        {:ok, nil}

      value ->
        case UUIDv7.cast(value) do
          {:ok, id} -> {:ok, id}
          :error -> {:error, :bad_request, %{"project_id" => ["is invalid"]}}
        end
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
