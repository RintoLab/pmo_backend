defmodule RintoPMOWeb.V1.CalibrationController do
  use RintoPMOWeb, :controller

  alias RintoPMO.Calendar
  alias RintoPMO.Calibration

  # Two years. The window is over finished work, so unlike `/schedule` there is
  # no projection-of-a-projection to guard against -- but a chart of a hundred
  # weeks is not read, and the limit keeps one accidental request from summing
  # the whole table.
  @max_weeks 104

  @doc """
  How the estimates compared with what actually happened.

  Both groupings in one response. They answer the same question from two
  sides -- is the arithmetic holding week to week, and is the story-point
  ladder meaning anything -- and a client that had to make two calls would
  show two windows that could disagree.

  `from` defaults to twelve weeks back and `to` to today, which is the span a
  calibration is actually read over: long enough to have finished work in it,
  short enough that the estimator being checked is the current one.
  """
  def index(conn, params) do
    with {:ok, to} <- date_param(params, "to", Date.utc_today()),
         {:ok, from} <- date_param(params, "from", Date.add(to, -7 * 12)),
         {:ok, project_id} <- project_param(params),
         :ok <- validate_span(from, to) do
      render(conn, :index,
        weeks: Calibration.weeks(from, to, project_id),
        difficulty: Calibration.by_difficulty(from, to, project_id)
      )
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
    cond do
      Date.after?(from, to) ->
        {:error, :bad_request, %{"from" => ["must not be after to"]}}

      length(Calendar.weeks(Calendar.monday_of(from), Calendar.monday_of(to))) > @max_weeks ->
        {:error, :bad_request, %{"to" => ["must be at most #{@max_weeks} weeks after from"]}}

      true ->
        :ok
    end
  end
end
