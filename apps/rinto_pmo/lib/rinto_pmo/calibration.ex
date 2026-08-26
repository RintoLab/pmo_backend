defmodule RintoPMO.Calibration do
  @moduledoc """
  What the estimates turned out to be worth.

  This system spends a great deal of effort collecting three numbers -- a
  three-point estimate, a Fibonacci story point, and the minutes a task
  actually took -- and until now nothing put them next to each other. An
  estimator that is never checked against what happened is not an estimator,
  it is a habit, and `RintoPMO.Agent.TaskEstimator` had no way to be calibrated
  because the comparison had no home.

  Two groupings, because there are two questions.

  ## By week: is the plan's arithmetic holding

  Tasks are counted in the week they were *finished*. Velocity is work
  delivered per week, and the week something was started in says nothing about
  when it was delivered.

  Weeks with nothing in them are returned as zeroes rather than left out. A
  gap is a fact about the plan, and a chart that closed it up would draw four
  productive weeks where there were two.

  ## By story point: is the ladder meaning anything

  A Fibonacci point is a rating, not a duration, and the only way it becomes
  useful is by learning what a 5 has historically cost. All seven rungs come
  back, including the ones nothing has been rated with -- "no data at this
  rung" is what a reader most needs to know before trusting a number from it.

  The middle value rather than the average: with a handful of tasks per rung,
  one that ran three days moves a mean somewhere no task ever was, and the
  result looks like knowledge.

  ## Only what can be compared is summed

  A sum of estimates over every finished task next to a sum of durations over
  every finished task is two totals over two different populations, and their
  ratio means nothing. So the minutes here are summed over the tasks that
  carry **both** an estimate and a recorded duration, and the ones left out
  are counted and reported by name -- `unestimated` and `unmeasured` are how a
  reader knows how much of the comparison to believe.

  Nothing here is a forecast. `RintoPMO.Schedule` plans forward from what a
  week can hold; this reads backwards from what was measured, and the two are
  never mixed.
  """

  use RintoPMO, :context

  alias RintoPMO.Calendar
  alias RintoPMO.Tasks.Task

  @typedoc """
  One week of finished work, and how it compared to what was expected.

  `expected_minutes` and `actual_minutes` are summed over `comparable` tasks
  only -- the ones carrying both numbers. Both are zero when `comparable` is
  zero, which is why the counts have to be read with them.
  """
  @type week_row :: %{
          week: Date.t(),
          completed: non_neg_integer(),
          comparable: non_neg_integer(),
          expected_minutes: non_neg_integer(),
          actual_minutes: non_neg_integer(),
          unestimated: non_neg_integer(),
          unmeasured: non_neg_integer()
        }

  @typedoc """
  One rung of the story-point ladder, as the clock found it.

  `median_actual_minutes` is nil when nothing at this rung was ever measured,
  which is different from a rung that is genuinely quick.
  """
  @type difficulty_row :: %{
          difficulty: pos_integer(),
          tasks: non_neg_integer(),
          measured: non_neg_integer(),
          median_actual_minutes: non_neg_integer() | nil
        }

  @doc """
  Finished work grouped by the week it was finished in, oldest first.

  Every week between `from` and `to` appears, empty ones included.
  """
  @spec weeks(Date.t(), Date.t(), UUIDv7.t() | nil) :: [week_row()]
  def weeks(%Date{} = from, %Date{} = to, project_id \\ nil) do
    by_week =
      from
      |> completed_between(to, project_id)
      |> Enum.group_by(&Calendar.monday_of(DateTime.to_date(&1.completed_at)))

    from
    |> Calendar.monday_of()
    |> Calendar.weeks(Calendar.monday_of(to))
    |> Enum.map(&week_row(&1, Map.get(by_week, &1, [])))
  end

  @doc """
  Finished work grouped by the story point it was rated with.

  All seven rungs, in order, whether or not anything reached them.
  """
  @spec by_difficulty(Date.t(), Date.t(), UUIDv7.t() | nil) :: [difficulty_row()]
  def by_difficulty(%Date{} = from, %Date{} = to, project_id \\ nil) do
    rated =
      from
      |> completed_between(to, project_id)
      |> Enum.filter(& &1.difficulty)
      |> Enum.group_by(& &1.difficulty)

    Enum.map(Task.difficulties(), &difficulty_row(&1, Map.get(rated, &1, [])))
  end

  # Finished, not merely stopped. `completed_at` is set by the transition that
  # owns it and cleared by `reopen`, so its presence is the whole of "this was
  # delivered" -- cancelled work never has one, and it should not: time spent
  # on something that was dropped is not what a finished estimate cost.
  #
  # Covers are excluded rather than filtered later: their estimate and their
  # actual are sums over the children, and counting both would count the same
  # work twice.
  defp completed_between(from, to, project_id) do
    finished_before = DateTime.new!(Date.add(to, 1), ~T[00:00:00.000000])
    finished_after = DateTime.new!(from, ~T[00:00:00.000000])

    Task
    |> where([task], task.kind == :work)
    |> where([task], not is_nil(task.completed_at))
    |> where([task], task.completed_at >= ^finished_after)
    |> where([task], task.completed_at < ^finished_before)
    |> then(fn query ->
      if project_id, do: where(query, [task], task.project_id == ^project_id), else: query
    end)
    |> Repo.all()
  end

  defp week_row(week, tasks) do
    comparable = Enum.filter(tasks, &comparable?/1)

    %{
      week: week,
      completed: length(tasks),
      comparable: length(comparable),
      expected_minutes: Enum.sum_by(comparable, &Task.expected/1),
      actual_minutes: Enum.sum_by(comparable, & &1.actual_minutes),
      unestimated: Enum.count(tasks, &is_nil(&1.estimate_optimistic)),
      unmeasured: Enum.count(tasks, &is_nil(&1.actual_minutes))
    }
  end

  defp comparable?(%Task{estimate_optimistic: nil}), do: false
  defp comparable?(%Task{actual_minutes: nil}), do: false
  defp comparable?(%Task{}), do: true

  defp difficulty_row(difficulty, tasks) do
    measured = tasks |> Enum.map(& &1.actual_minutes) |> Enum.reject(&is_nil/1)

    %{
      difficulty: difficulty,
      tasks: length(tasks),
      measured: length(measured),
      median_actual_minutes: median(measured)
    }
  end

  defp median([]), do: nil

  defp median(minutes) do
    sorted = Enum.sort(minutes)
    middle = div(length(sorted), 2)

    case rem(length(sorted), 2) do
      1 -> Enum.at(sorted, middle)
      0 -> round((Enum.at(sorted, middle - 1) + Enum.at(sorted, middle)) / 2)
    end
  end
end
