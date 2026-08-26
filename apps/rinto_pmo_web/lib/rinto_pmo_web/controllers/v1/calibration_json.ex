defmodule RintoPMOWeb.V1.CalibrationJSON do
  @moduledoc """
  Estimates against what happened, grouped two ways.

  `weeks` is the time series and `difficulty` is the ladder. Neither carries a
  ratio: dividing here would put one number in front of a reader who cannot
  see how many tasks it was built from, and with a handful of tasks a week
  that is the difference between a signal and a coincidence. The counts are
  right beside the sums so that the division can be made knowingly.

  For the same reason nothing is filled in. `expected_minutes` and
  `actual_minutes` are summed over the tasks that carry both -- `comparable`
  says how many that was, and `unestimated` and `unmeasured` say what was left
  out and why.
  """

  def index(%{weeks: weeks, difficulty: difficulty}) do
    %{
      data: %{
        weeks: Enum.map(weeks, &week/1),
        difficulty: Enum.map(difficulty, &rung/1)
      }
    }
  end

  defp week(row) do
    %{
      week: row.week,
      completed: row.completed,
      comparable: row.comparable,
      expected_minutes: row.expected_minutes,
      actual_minutes: row.actual_minutes,
      unestimated: row.unestimated,
      unmeasured: row.unmeasured
    }
  end

  defp rung(row) do
    %{
      difficulty: row.difficulty,
      tasks: row.tasks,
      measured: row.measured,
      median_actual_minutes: row.median_actual_minutes
    }
  end
end
