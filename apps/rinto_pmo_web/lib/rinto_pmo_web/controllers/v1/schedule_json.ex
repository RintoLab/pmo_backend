defmodule RintoPMOWeb.V1.ScheduleJSON do
  alias RintoPMO.Calendar
  alias RintoPMOWeb.V1.TaskJSON

  @doc """
  One object per week, earliest first.
  """
  def index(%{weeks: weeks}) do
    %{data: Enum.map(weeks, &week/1)}
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

    %{
      week: week,
      capacity: capacity,
      calendar_known: plan.calendar_known,
      allocated: Enum.sum_by(allocations, & &1.minutes),
      days: Enum.map(Enum.sort(Map.keys(days), Date), &day(&1, Map.fetch!(days, &1))),
      overflow: Enum.map(plan.overflow, &TaskJSON.data/1),
      blocked: Enum.map(plan.blocked, &TaskJSON.data/1)
    }
  end

  defp day(day, allocations) do
    %{
      day: day,
      allocated: Enum.sum_by(allocations, & &1.minutes),
      capacity: Calendar.daily_capacity(),
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
