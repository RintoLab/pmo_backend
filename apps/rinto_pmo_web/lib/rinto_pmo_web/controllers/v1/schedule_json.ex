defmodule RintoPMOWeb.V1.ScheduleJSON do
  alias RintoPMOWeb.V1.TaskJSON

  @doc """
  One object per week, earliest first.
  """
  def index(%{weeks: weeks}) do
    %{data: Enum.map(weeks, &week/1)}
  end

  @doc """
  One object per task that was worked in the window, oldest start first.

  Flat rather than grouped by week, unlike `index/1`: a task's work spans days
  and often weeks, and filing it under one of them would make a client that
  wants the bar reassemble it. The dates are here; a client that wants weeks
  groups by them.

  `slip_weeks` is measured from `first_planned_on`, not from `planned_on`.
  Rescheduling moves the latter, so slip measured against it is zero for every
  task however many times it was pushed. Null means the task was never
  selected into a week at all -- which is not a slip of zero.

  `expected_minutes` and `actual_minutes` are both nullable and neither is
  filled in. A missing estimate or a missing recorded duration is a gap in
  what was measured, and a zero there would read as a measurement.
  """
  def history(%{records: records}) do
    %{data: Enum.map(records, &record/1)}
  end

  defp record(entry) do
    %{
      task: TaskJSON.data(entry.task),
      started_on: entry.started_on,
      completed_on: entry.completed_on,
      planned_on: entry.planned_on,
      first_planned_on: entry.first_planned_on,
      slip_weeks: entry.slip_weeks,
      expected_minutes: entry.expected_minutes,
      actual_minutes: entry.actual_minutes
    }
  end

  # `capacity` comes from the packer rather than being recomputed here: in the
  # current week the days already behind us hold nothing, and a renderer that
  # worked that out for itself would be a second copy of a rule that lives in
  # `RintoPMO.Schedule`.
  #
  # `overflow` is the point of the whole endpoint. It names the tasks that were
  # selected into this week and did not fit, which answers "is this plan
  # realistic" in a way a percentage cannot.
  #
  # `blocked` is kept apart from it deliberately. Overflow means the week is
  # too full and the answer is to cut work; blocked means a prerequisite did
  # not make it and the answer is upstream. Merging them would send whoever
  # read the list to cut work that was never the problem.
  # `calendar_known` false means this week sits in a year whose holidays were
  # never fetched, so `capacity` came from the weekend rule alone -- in China
  # that plans Spring Festival as five ordinary working days. The week is still
  # answered, because refusing helps nobody, but a client that shows the number
  # without showing this is presenting a guess as a fact.
  defp week(%{week: week, capacity: capacity, allocations: allocations} = plan) do
    days = Enum.group_by(allocations, & &1.day)
    capacities = Map.new(plan.capacities)

    %{
      week: week,
      capacity: capacity,
      calendar_known: plan.calendar_known,
      allocated: Enum.sum_by(allocations, & &1.minutes),
      days:
        Enum.map(
          Enum.sort(Map.keys(days), Date),
          &day(&1, Map.fetch!(days, &1), Map.fetch!(capacities, &1))
        ),
      overflow: Enum.map(plan.overflow, &TaskJSON.data/1),
      blocked: Enum.map(plan.blocked, &TaskJSON.data/1)
    }
  end

  # `capacity` is this day's, not `Calendar.daily_capacity/0`. Leave comes off
  # a day by the minute, so a Tuesday somebody is away for two hours of is 360
  # minutes long, and a bar drawn against a hardcoded 480 would show it as
  # comfortably under when it was full.
  #
  # A day with no minutes left is not here at all -- it received no work, so it
  # has no entry. Which day that is, and why, is `GET /calendar/days`.
  defp day(day, allocations, capacity) do
    %{
      day: day,
      allocated: Enum.sum_by(allocations, & &1.minutes),
      capacity: capacity,
      tasks: Enum.map(allocations, &allocation/1)
    }
  end

  # The task whole, plus how much of *this* day it takes. A client drawing a
  # bar needs both, and a task that spans two days appears under each with its
  # own share -- the shares sum to the estimate, never more.
  defp allocation(%{task: task, minutes: minutes}) do
    %{minutes: minutes, task: TaskJSON.data(task)}
  end
end
