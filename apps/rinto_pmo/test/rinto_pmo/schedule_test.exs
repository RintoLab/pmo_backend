defmodule RintoPMO.ScheduleTest do
  use RintoPMO.DataCase, async: true

  alias RintoPMO.Calendar
  alias RintoPMO.Schedule

  # Filling is tested against next week rather than this one, because this one
  # has however many days left that the suite happened to run on, while a future
  # week always has all five. The current week gets its own tests, below.
  setup do
    week = Calendar.next_week(Calendar.current_week())

    %{
      week: week,
      next_week: Calendar.next_week(week),
      days: Calendar.workdays_in(Calendar.none(), week)
    }
  end

  # `expected/1` of a flat three-point estimate is the number itself, which
  # keeps the arithmetic in these tests readable.
  defp scheduled(minutes, attrs) do
    insert(
      :task,
      Keyword.merge(
        [
          estimate_optimistic: minutes,
          estimate_likely: minutes,
          estimate_pessimistic: minutes
        ],
        attrs
      )
    )
  end

  defp for_week(plans, week), do: Enum.find(plans, &(&1.week == week))

  defp minutes_on(plan, day) do
    plan.allocations
    |> Enum.filter(&(&1.day == day))
    |> Enum.sum_by(& &1.minutes)
  end

  defp allocated_ids(plan), do: Enum.map(plan.allocations, & &1.task.id)

  describe "pack/2 selection" do
    test "a task with no planned_start_on is never a candidate", %{week: week} do
      scheduled(120, planned_start_on: nil)

      plan = week |> Schedule.pack(week) |> for_week(week)

      assert plan.allocations == []
      assert plan.overflow == []
    end

    test "a task selected for a later week is not a candidate for this one", %{
      week: week,
      next_week: next_week
    } do
      task = scheduled(120, planned_start_on: next_week)

      plans = Schedule.pack(week, next_week)

      assert for_week(plans, week).allocations == []
      assert allocated_ids(for_week(plans, next_week)) == [task.id]
    end

    test "a finished task is not a candidate", %{week: week} do
      scheduled(120, planned_start_on: week, status: :done)

      assert week |> Schedule.pack(week) |> for_week(week) |> Map.fetch!(:allocations) == []
    end

    test "a task with no estimate is not a candidate", %{week: week} do
      insert(:task, planned_start_on: week)

      assert week |> Schedule.pack(week) |> for_week(week) |> Map.fetch!(:allocations) == []
    end
  end

  describe "pack/2 filling" do
    test "a task lands on the day it was selected for", %{week: week, days: [monday | _]} do
      task = scheduled(120, planned_start_on: monday)

      plan = week |> Schedule.pack(week) |> for_week(week)

      assert [%{day: ^monday, minutes: 120, task: %{id: id}}] = plan.allocations
      assert id == task.id
    end

    test "a task spills into the next day when the one it started in is partly full", %{
      week: week,
      days: [monday, tuesday | _]
    } do
      scheduled(300, planned_start_on: monday, priority: 1)
      spilling = scheduled(300, planned_start_on: monday, priority: 2)

      plan = week |> Schedule.pack(week) |> for_week(week)

      assert minutes_on(plan, monday) == Calendar.daily_capacity()

      spilled = Enum.filter(plan.allocations, &(&1.task.id == spilling.id))
      assert [%{day: ^monday, minutes: 180}, %{day: ^tuesday, minutes: 120}] = spilled
    end

    test "a task cannot take a day earlier than the one it was selected for", %{
      week: week,
      days: [monday, _tuesday, wednesday | _]
    } do
      task = scheduled(120, planned_start_on: wednesday)

      plan = week |> Schedule.pack(week) |> for_week(week)

      assert minutes_on(plan, monday) == 0
      assert [%{day: ^wednesday, task: %{id: id}}] = plan.allocations
      assert id == task.id
    end
  end

  describe "pack/2 overflow" do
    test "what does not fit is reported by name rather than pushed forward", %{
      week: week,
      next_week: next_week,
      days: [monday | _]
    } do
      for _ <- 1..5, do: scheduled(480, planned_start_on: monday, priority: 1)
      cut = scheduled(60, planned_start_on: monday, priority: 2)

      plans = Schedule.pack(week, next_week)
      this_week = for_week(plans, week)

      assert Enum.sum_by(this_week.allocations, & &1.minutes) ==
               Calendar.week_capacity(Calendar.none(), week)

      assert Enum.map(this_week.overflow, & &1.id) == [cut.id]

      # It carries forward, and nothing that was allocated does.
      assert allocated_ids(for_week(plans, next_week)) == [cut.id]
    end

    test "priority decides who is cut, not age or the day selected", %{
      week: week,
      days: [monday | _]
    } do
      for _ <- 1..4, do: scheduled(480, planned_start_on: monday, priority: 3)
      low = scheduled(480, planned_start_on: monday, priority: 5)
      high = scheduled(480, planned_start_on: monday, priority: 1)

      plan = week |> Schedule.pack(week) |> for_week(week)

      assert high.id in allocated_ids(plan)
      assert Enum.map(plan.overflow, & &1.id) == [low.id]
    end

    test "a smaller task still gets in behind one that did not fit", %{
      week: week,
      days: [monday | _]
    } do
      for _ <- 1..4, do: scheduled(480, planned_start_on: monday, priority: 1)
      scheduled(300, planned_start_on: monday, priority: 2)
      too_big = scheduled(480, planned_start_on: monday, priority: 3)
      small = scheduled(180, planned_start_on: monday, priority: 4)

      plan = week |> Schedule.pack(week) |> for_week(week)

      assert Enum.map(plan.overflow, & &1.id) == [too_big.id]
      assert small.id in allocated_ids(plan)
    end
  end

  describe "pack/2 and the past" do
    test "the current week offers only the days that are left", %{} do
      current = Calendar.current_week()
      today = Date.utc_today()

      # Selected for the first day of this week, which may already be behind us.
      scheduled(120, planned_start_on: current)

      plan = current |> Schedule.pack(current) |> for_week(current)

      # Nothing lands only when the week has nothing left to offer, which on a
      # weekend is the whole of it -- comparing against the week's workdays in
      # the abstract made this fail every Saturday and Sunday.
      remaining =
        Calendar.none()
        |> Calendar.capacities_in(current)
        |> Enum.reject(fn {day, _minutes} -> Date.before?(day, today) end)

      assert plan.allocations != [] or remaining == []
      assert Enum.all?(plan.allocations, &(not Date.before?(&1.day, today)))
    end

    test "weeks before the current one are not returned" do
      current = Calendar.current_week()
      last_week = Date.add(current, -7)

      assert [%{week: ^current}] = Schedule.pack(last_week, current)
    end

    test "a backwards range is empty", %{week: week} do
      assert Schedule.pack(week, Date.add(week, -7)) == []
    end

    test "any day in a week names that week", %{week: week, days: days} do
      friday = List.last(days)

      assert [%{week: ^week}] = Schedule.pack(friday, friday)
    end
  end

  describe "pack/2 dependencies" do
    defp depends(waiting, prerequisite) do
      {:ok, _} = RintoPMO.Tasks.add_dependency(waiting, prerequisite.id)
      :ok
    end

    test "a prerequisite is filled before the work waiting on it, whatever the priority", %{
      week: week,
      days: [monday | _]
    } do
      prerequisite = scheduled(120, planned_start_on: monday, priority: 5)
      waiting = scheduled(120, planned_start_on: monday, priority: 1)
      :ok = depends(waiting, prerequisite)

      plan = week |> Schedule.pack(week) |> for_week(week)

      # Priority alone would have put the P1 first.
      assert allocated_ids(plan) == [prerequisite.id, waiting.id]
    end

    test "a chain is filled in order", %{week: week, days: [monday | _]} do
      a = scheduled(60, planned_start_on: monday, priority: 1)
      b = scheduled(60, planned_start_on: monday, priority: 1)
      c = scheduled(60, planned_start_on: monday, priority: 1)
      :ok = depends(b, a)
      :ok = depends(c, b)

      plan = week |> Schedule.pack(week) |> for_week(week)

      assert allocated_ids(plan) == [a.id, b.id, c.id]
    end

    test "work whose prerequisite overflowed is blocked, not overflowed", %{
      week: week,
      days: [monday | _]
    } do
      # Fills the week exactly, so the prerequisite cannot fit.
      for _ <- 1..5, do: scheduled(480, planned_start_on: monday, priority: 1)

      prerequisite = scheduled(60, planned_start_on: monday, priority: 2)
      waiting = scheduled(60, planned_start_on: monday, priority: 2)
      :ok = depends(waiting, prerequisite)

      plan = week |> Schedule.pack(week) |> for_week(week)

      # Two different facts, kept apart: the prerequisite did not fit, and the
      # work waiting on it did not happen for a different reason entirely.
      assert Enum.map(plan.overflow, & &1.id) == [prerequisite.id]
      assert Enum.map(plan.blocked, & &1.id) == [waiting.id]
    end

    test "blocking is transitive without a second pass", %{week: week, days: [monday | _]} do
      for _ <- 1..5, do: scheduled(480, planned_start_on: monday, priority: 1)

      a = scheduled(60, planned_start_on: monday, priority: 2)
      b = scheduled(60, planned_start_on: monday, priority: 2)
      c = scheduled(60, planned_start_on: monday, priority: 2)
      :ok = depends(b, a)
      :ok = depends(c, b)

      plan = week |> Schedule.pack(week) |> for_week(week)

      assert Enum.map(plan.overflow, & &1.id) == [a.id]
      assert Enum.map(plan.blocked, & &1.id) == [b.id, c.id]
    end

    test "a prerequisite allocated in an earlier week holds nothing up", %{
      week: week,
      next_week: next_week,
      days: [monday | _]
    } do
      prerequisite = scheduled(60, planned_start_on: monday, priority: 1)
      waiting = scheduled(60, planned_start_on: next_week, priority: 1)
      :ok = depends(waiting, prerequisite)

      plans = Schedule.pack(week, next_week)

      assert allocated_ids(for_week(plans, week)) == [prerequisite.id]
      assert allocated_ids(for_week(plans, next_week)) == [waiting.id]
      assert for_week(plans, next_week).blocked == []
    end

    test "a done prerequisite is not in the pool and constrains nothing", %{
      week: week,
      days: [monday | _]
    } do
      prerequisite = scheduled(60, planned_start_on: monday, priority: 1, status: :done)
      waiting = scheduled(60, planned_start_on: monday, priority: 1)
      :ok = depends(waiting, prerequisite)

      plan = week |> Schedule.pack(week) |> for_week(week)

      assert allocated_ids(plan) == [waiting.id]
      assert plan.blocked == []
    end
  end

  describe "sequence/2" do
    test "ignores edges pointing outside the given tasks", %{week: week} do
      a = scheduled(60, planned_start_on: week, priority: 1)
      b = scheduled(60, planned_start_on: week, priority: 2)

      assert Enum.map(Schedule.sequence([a, b], %{b.id => [UUIDv7.generate()]}), & &1.id) ==
               [a.id, b.id]
    end

    test "keeps everything even if the graph somehow looped", %{week: week} do
      a = scheduled(60, planned_start_on: week, priority: 1)
      b = scheduled(60, planned_start_on: week, priority: 2)

      # Not reachable through `add_dependency/2`; losing work would be worse
      # than planning it in a questionable order.
      sequenced = Schedule.sequence([a, b], %{a.id => [b.id], b.id => [a.id]})

      assert Enum.map(sequenced, & &1.id) |> Enum.sort() == Enum.sort([a.id, b.id])
    end
  end

  describe "order/1" do
    test "priority first, then the day selected, then age", %{week: week} do
      later_but_urgent = scheduled(60, planned_start_on: Date.add(week, 3), priority: 1)
      carried_over = scheduled(60, planned_start_on: Date.add(week, -7), priority: 4)

      assert Enum.map(Schedule.order([carried_over, later_but_urgent]), & &1.id) ==
               [later_but_urgent.id, carried_over.id]
    end
  end

  describe "history/3" do
    defp worked(attrs) do
      insert(:task, Keyword.merge([status: :done], attrs))
    end

    defp at(%Date{} = day), do: DateTime.new!(day, ~T[09:00:00.000000])

    test "reports work whose span overlaps the window, oldest start first" do
      inside = worked(started_at: at(~D[2026-06-10]), completed_at: at(~D[2026-06-11]))
      spanning = worked(started_at: at(~D[2026-06-01]), completed_at: at(~D[2026-06-30]))
      running = worked(status: :in_progress, started_at: at(~D[2026-06-05]), completed_at: nil)

      worked(started_at: at(~D[2026-05-01]), completed_at: at(~D[2026-05-02]))
      worked(started_at: at(~D[2026-07-01]), completed_at: at(~D[2026-07-02]))
      insert(:task, started_at: nil)

      assert [spanning.id, running.id, inside.id] ==
               ~D[2026-06-08]
               |> Schedule.history(~D[2026-06-14])
               |> Enum.map(& &1.task.id)
    end

    # It really was worked. A record that dropped it would make the week look
    # cheaper than it was.
    test "cancelled work that was started is still part of the record" do
      dropped =
        worked(status: :cancelled, started_at: at(~D[2026-06-10]), completed_at: nil)

      assert [dropped.id] ==
               ~D[2026-06-08]
               |> Schedule.history(~D[2026-06-14])
               |> Enum.map(& &1.task.id)
    end

    # The whole point of the baseline column: a task pushed three weeks and
    # then worked has slipped three weeks, however tidy `planned_start_on`
    # looks by the time anybody reads it.
    test "slip is measured from the first plan, not the current one" do
      task =
        worked(
          planned_start_on: ~D[2026-06-08],
          first_planned_on: ~D[2026-05-18],
          started_at: at(~D[2026-06-09]),
          completed_at: at(~D[2026-06-10]),
          estimate_optimistic: 60,
          estimate_likely: 120,
          estimate_pessimistic: 240,
          actual_minutes: 300
        )

      assert [entry] = Schedule.history(~D[2026-06-08], ~D[2026-06-14])

      assert entry.task.id == task.id
      assert entry.started_on == ~D[2026-06-09]
      assert entry.completed_on == ~D[2026-06-10]
      assert entry.planned_on == ~D[2026-06-08]
      assert entry.first_planned_on == ~D[2026-05-18]
      assert entry.slip_weeks == 3
      assert entry.expected_minutes == 130
      assert entry.actual_minutes == 300
    end

    # A week is the unit the plan is made in, so beginning on Wednesday what
    # was selected for Monday is not a slip.
    test "starting later in the same week is not a slip, and never planned is not zero" do
      worked(
        first_planned_on: ~D[2026-06-08],
        planned_start_on: ~D[2026-06-08],
        started_at: at(~D[2026-06-10])
      )

      unplanned = worked(started_at: at(~D[2026-06-11]))

      records = Schedule.history(~D[2026-06-08], ~D[2026-06-14])

      assert Enum.map(records, & &1.slip_weeks) == [0, nil]
      assert Enum.find(records, &(&1.task.id == unplanned.id)).first_planned_on == nil
    end

    test "nothing is filled in for an estimate or a duration nobody recorded" do
      worked(started_at: at(~D[2026-06-10]), actual_minutes: nil)

      assert [%{expected_minutes: nil, actual_minutes: nil}] =
               Schedule.history(~D[2026-06-08], ~D[2026-06-14])
    end

    # Unlike `pack/2`, which refuses to be scoped. That refusal is about
    # arithmetic; nothing about the past is computed across projects.
    test "narrows to one project when asked" do
      mine = insert(:project)
      theirs = insert(:project)
      here = worked(project: mine, started_at: at(~D[2026-06-10]))
      worked(project: theirs, started_at: at(~D[2026-06-10]))

      assert [here.id] ==
               ~D[2026-06-08]
               |> Schedule.history(~D[2026-06-14], mine.id)
               |> Enum.map(& &1.task.id)
    end
  end
end
