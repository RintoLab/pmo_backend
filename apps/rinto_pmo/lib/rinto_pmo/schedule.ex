defmodule RintoPMO.Schedule do
  @moduledoc """
  Fills a week's minutes with the work that was selected into it.

  A week holds `RintoPMO.Calendar.week_capacity/1` minutes. `pack/2` walks the
  tasks that were selected into it, in priority order, and gives each one the
  minutes it needs until the week runs out. What is left over is *reported*,
  not pushed forward into a week it was never selected for.

  ## Filling, not forecasting

  The boundary is a week, not "until the queue is empty". A great many tasks
  are never going to be worked, and computing a landing day for each of them
  produces dates forty weeks out that are an artifact of sorting rather than a
  prediction of anything. The useful signal is the edge: what fit and what did
  not.

  So `overflow` is the answer to "is this week's plan realistic", and it is a
  better one than a day-by-day overage figure, because it names the tasks.

  ## Selection is `planned_start_on`, and nothing else

  A task is a candidate for a week when `planned_start_on` falls in that week
  or earlier. Null is the backlog: never a candidate, anywhere, so the low
  priority work that is never going to happen costs nothing to carry and does
  not need a mechanism of its own to be kept out.

  The column also bounds where a task may land *within* a week. It reads "not
  before this day", so a task selected for Wednesday cannot take Monday's
  minutes even when Monday is empty.

  ## Weeks are a chain, not independent

  Work allocated in a week is taken to be finished by the end of it, and drops
  out of the following week's candidates. Only `overflow` carries forward.

  Packing each week from the same pool instead would count this week's open
  work again next week, and show next week as hopeless before it began. That
  is why the walk always starts at the current week even when the caller asked
  about a later one: the weeks in between have to be run to know what is left.

  The past is not packed at all. What happened before today is `started_at` and
  `completed_at`, a record; the plan is a forecast, and forecasting backwards
  is not a thing.

  ## Overflow does not stop the fill

  When a task does not fit in what remains of a week, the ones after it are
  still tried, and a smaller one may get in ahead of it. This is deliberate:
  the alternative wastes the remainder of the week to protect an ordering that
  nothing is hiding anyway -- the task that missed out is right there in
  `overflow`, by name. Same information, more of the week used.

  ## Dependencies order the fill, and can keep work out of it

  A task is filled after everything it waits for, so the week is walked in
  topological order with `order/1` breaking ties. Priority decides between two
  tasks that could each go next; it never decides that work happens before its
  own prerequisite.

  Most conflicts never reach here: `RintoPMO.Tasks` refuses to schedule a task
  ahead of a live prerequisite in the first place. What it cannot refuse is
  capacity. A prerequisite selected for this week may not *fit* in this week,
  and then the work waiting on it must not be filled either -- so it lands in
  `blocked` rather than `overflow`.

  Two lists rather than one, because they are two different facts with two
  different answers. `overflow` says the week is too full: cut work or accept
  less. `blocked` says something upstream did not happen: go deal with that.
  A single list would make the second look like the first and send whoever
  read it to cut work that was never the problem.

  A prerequisite that is `:done` or `:cancelled` holds nothing up. See
  `RintoPMO.Tasks.Dependency`.

  ## Capacity belongs to a person, and an estimate is already that person's time

  Nothing here filters by `assignee_id`, and that is not a simplification: an
  estimate measures what a task costs *the person planning it*, whoever or
  whatever executes it. A task an agent picks up still spends the time spent
  waiting on it and reviewing what came back, which is what the number was.

  So an agent needs no capacity of its own, and giving it one would be worse
  than useless -- how long a model took is not a stable unit. It runs
  concurrently with other things, with itself, and with the person; a figure
  built out of that would look like a resource and behave like noise.

  Which leaves one pool, belonging to whoever the plan is for. Today that is
  implicit because there is one of them. A second person is not a second pool
  competing for the same minutes -- it is a second target, planned separately
  by passing it in, and views that show several people at once simply lay the
  results over each other, a day being 480 minutes times however many people
  are in the picture.

  For the same reason nothing here filters by project. A week's minutes are
  shared across every project, so a per-project view has to pack everything and
  filter the *result* -- packing only one project's tasks would hand that
  project the whole week and quietly overstate what fits.
  """

  use RintoPMO, :context

  alias RintoPMO.Calendar
  alias RintoPMO.Tasks.Dependency
  alias RintoPMO.Tasks.Task

  @typedoc """
  One task's share of one day.
  """
  @type allocation :: %{day: Date.t(), task: Task.t(), minutes: non_neg_integer()}

  @typedoc """
  What a single week came to.

  `allocations` is in day order, and within a day in the order the tasks were
  filled. `overflow` is in priority order, so the first entry is the one that
  came closest to making it in.

  `calendar_known` is false when this week sits in a year whose holidays were
  never imported. The week is still planned -- refusing to answer helps nobody
  -- but Monday to Friday is all that is behind it, so anything presenting
  `capacity` has to pass this along rather than let a guess read as a fact.
  """
  @type week_plan :: %{
          week: Calendar.week(),
          capacity: non_neg_integer(),
          calendar_known: boolean(),
          allocations: [allocation()],
          overflow: [Task.t()],
          blocked: [Task.t()]
        }

  @doc """
  Plans every week from `from_week` through `to_week`, inclusive.

  Both arguments may be any date; the week each one falls in is what counts.
  Weeks before the current one are never returned -- ask for them and the
  answer starts at this week instead, because the plan does not run backwards.

  The walk itself always begins at the current week regardless of `from_week`,
  since a later week cannot be known without first knowing what the weeks
  before it consumed.
  """
  @spec pack(Date.t(), Date.t()) :: [week_plan()]
  def pack(%Date{} = from_week, %Date{} = to_week) do
    first = Enum.max([Calendar.monday_of(from_week), Calendar.current_week()], Date)
    last = Calendar.monday_of(to_week)

    if Date.before?(last, first) do
      []
    else
      start = Calendar.current_week()
      calendar = Calendar.load(start, last)

      start
      |> Calendar.weeks(last)
      |> plan_weeks(candidates(last), calendar)
      |> Enum.reject(&Date.before?(&1.week, first))
    end
  end

  @doc """
  The order tasks are given the week's minutes in.

  Priority first, and it is not a tie-breaker: work carried over from an
  earlier week has no claim to jump ahead of something more important that was
  selected for this one. Then the day it was selected for, then age.
  """
  @spec order([Task.t()]) :: [Task.t()]
  def order(tasks) when is_list(tasks), do: Enum.sort_by(tasks, &sort_key/1)

  defp sort_key(%Task{} = task) do
    {task.priority, day_key(task.planned_start_on), age_key(task.inserted_at)}
  end

  # Dates and datetimes are compared through their own modules rather than
  # structurally: a struct sorts by its keys in alphabetical order, which for a
  # `Date` means day before month before year.
  defp day_key(nil), do: {9999, 12, 31}
  defp day_key(%Date{} = date), do: Date.to_erl(date)

  defp age_key(nil), do: 0
  defp age_key(%DateTime{} = at), do: DateTime.to_unix(at, :microsecond)

  # Everything that could be a candidate for any week in the range, read once.
  # A summary node is absent by construction: it can hold no `planned_start_on`.
  defp candidates(last_week) do
    cutoff = Date.add(last_week, 6)

    Task
    |> where([task], task.kind == :work)
    |> where([task], task.status in ^Task.live_statuses())
    |> where([task], not is_nil(task.planned_start_on))
    |> where([task], not is_nil(task.estimate_optimistic))
    |> where([task], task.planned_start_on <= ^cutoff)
    |> Repo.all()
  end

  defp plan_weeks(weeks, pool, calendar) do
    edges = dependency_edges(pool)

    {plans, _pool} =
      Enum.map_reduce(weeks, pool, fn week, pool ->
        plan = fill(week, sequence(eligible(pool, week), edges), edges, calendar)
        {plan, drop_allocated(pool, plan)}
      end)

    plans
  end

  # Only the edges between tasks that could be scheduled at all. A prerequisite
  # that is `:done` or `:cancelled` is not in the pool, so its edge simply is
  # not here -- the "a dependency constrains only while it is live" rule ends up
  # costing nothing to enforce.
  defp dependency_edges(pool) do
    ids = Enum.map(pool, & &1.id)

    Dependency
    |> where([edge], edge.task_id in ^ids and edge.depends_on_id in ^ids)
    |> select([edge], {edge.task_id, edge.depends_on_id})
    |> Repo.all()
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
  end

  @doc """
  Orders tasks so that nothing comes before what it waits for.

  Kahn's algorithm, with `order/1` choosing among the tasks that are ready at
  each step: priority decides between two tasks that could each go next, and
  never decides that work happens before its own prerequisite.

  `edges` maps a task id to the ids it waits for. Edges pointing outside
  `tasks` are ignored here -- whether an absent prerequisite is satisfied or
  merely elsewhere is `fill/4`'s question, not this one's.

  Cannot loop: `RintoPMO.Tasks.add_dependency/2` refuses any edge that would
  close a cycle. If one somehow existed, the leftovers are appended in priority
  order rather than dropped, because losing work silently is worse than
  planning it in a questionable order.
  """
  @spec sequence([Task.t()], %{UUIDv7.t() => [UUIDv7.t()]}) :: [Task.t()]
  def sequence(tasks, edges) do
    present = MapSet.new(tasks, & &1.id)

    waiting =
      Map.new(tasks, fn task ->
        {task.id, edges |> Map.get(task.id, []) |> Enum.filter(&MapSet.member?(present, &1))}
      end)

    take_ready(order(tasks), waiting, [])
  end

  defp take_ready([], _waiting, done), do: Enum.reverse(done)

  defp take_ready(remaining, waiting, done) do
    case Enum.split_with(remaining, &(waiting |> Map.fetch!(&1.id) |> Enum.empty?())) do
      # Nothing is ready and something is left: only reachable through a cycle,
      # which `add_dependency/2` does not allow to exist.
      {[], stuck} ->
        Enum.reverse(done) ++ stuck

      {ready, blocked} ->
        satisfied = MapSet.new(ready, & &1.id)

        waiting =
          Map.new(waiting, fn {id, wants} ->
            {id, Enum.reject(wants, &MapSet.member?(satisfied, &1))}
          end)

        take_ready(blocked, waiting, Enum.reverse(ready) ++ done)
    end
  end

  # Selected into this week or any earlier one. The cutoff is the week's last
  # calendar day rather than its last workday, so a task somebody parked on a
  # Saturday is a candidate that visibly fails to fit rather than one that
  # quietly is not asked about.
  defp eligible(pool, week) do
    cutoff = Date.add(week, 6)

    pool
    |> Enum.filter(&(not Date.after?(&1.planned_start_on, cutoff)))
    |> order()
  end

  defp drop_allocated(pool, %{allocations: allocations}) do
    placed = MapSet.new(allocations, & &1.task.id)
    Enum.reject(pool, &MapSet.member?(placed, &1.id))
  end

  # Days already behind us hold nothing, which matters only in the current week
  # and matters a lot there: on a Thursday, three of this week's five days are
  # spent, and filling them would report a week that fits far more than it can.
  # A future week loses nothing to this filter.
  defp fill(week, tasks, edges, calendar) do
    today = Date.utc_today()

    buckets =
      calendar
      |> Calendar.workdays_in(week)
      |> Enum.reject(&Date.before?(&1, today))
      |> Enum.map(&{&1, Calendar.daily_capacity()})

    # `tasks` is already in topological order, so by the time a task is reached
    # every prerequisite of it that is in this week has had its turn. `missing`
    # collects the ones whose turn ended without a place -- overflowed, or
    # blocked themselves -- and anything waiting on those cannot be filled
    # either. That is what makes the effect transitive with no second pass.
    {_buckets, allocations, overflow, blocked, _missing} =
      Enum.reduce(tasks, {buckets, [], [], [], MapSet.new()}, &place_or_defer(&1, &2, edges))

    %{
      week: week,
      # What this week had to give, before any of it was spent -- the days
      # already behind us are not in `buckets` at all, so in the current week
      # this is smaller than `Calendar.week_capacity/1`. That is the number to
      # compare a load against, and it is reported from here because this is
      # where the days were chosen. Recomputing it in a renderer would be a
      # second copy of the same rule, free to drift from this one.
      capacity: Enum.sum_by(buckets, fn {_day, free} -> free end),
      calendar_known: Calendar.week_known?(calendar, week),
      # Stable, so a day's slices stay in the order they were filled.
      allocations: Enum.sort_by(allocations, &Date.to_erl(&1.day)),
      overflow: Enum.reverse(overflow),
      blocked: Enum.reverse(blocked)
    }
  end

  # One task's turn. Blocked wins over overflow: a task whose prerequisite did
  # not happen is not competing for minutes at all, so it never gets as far as
  # being measured against what is left of the week.
  defp place_or_defer(task, {buckets, allocations, overflow, blocked, missing}, edges) do
    if blocked_by?(task, edges, missing) do
      {buckets, allocations, overflow, [task | blocked], MapSet.put(missing, task.id)}
    else
      case place(buckets, task) do
        {:ok, buckets, slices} ->
          {buckets, allocations ++ slices, overflow, blocked, missing}

        :error ->
          {buckets, allocations, [task | overflow], blocked, MapSet.put(missing, task.id)}
      end
    end
  end

  defp blocked_by?(%Task{} = task, edges, missing) do
    edges
    |> Map.get(task.id, [])
    |> Enum.any?(&MapSet.member?(missing, &1))
  end

  # All of a task or none of it. A task half-placed in a week would be a task
  # the next week is entitled to treat as finished, which it is not.
  defp place(buckets, %Task{} = task) do
    needed = Task.expected(task)

    cond do
      needed == 0 -> place_weightless(buckets, task)
      needed > free_minutes(buckets, task) -> :error
      true -> take(buckets, task, needed)
    end
  end

  # A task estimated at nothing consumes nothing, and would otherwise vanish
  # from the board it was selected onto. It gets a slice of zero minutes on the
  # first day it is allowed to start.
  defp place_weightless(buckets, %Task{} = task) do
    case Enum.find(buckets, &startable?(&1, task)) do
      nil -> :error
      {day, _free} -> {:ok, buckets, [%{day: day, task: task, minutes: 0}]}
    end
  end

  defp take(buckets, %Task{} = task, needed) do
    # The capacity check in `place/2` has already run, so the fold always ends
    # with nothing left over. Matching on it says so.
    {filled, slices, 0} =
      Enum.reduce(buckets, {[], [], needed}, fn {day, free} = bucket, {filled, slices, left} ->
        case usable?(bucket, task) && min(free, left) do
          minutes when is_integer(minutes) and minutes > 0 ->
            {[{day, free - minutes} | filled],
             [%{day: day, task: task, minutes: minutes} | slices], left - minutes}

          _nothing ->
            {[bucket | filled], slices, left}
        end
      end)

    {:ok, Enum.reverse(filled), Enum.reverse(slices)}
  end

  defp free_minutes(buckets, task) do
    Enum.sum_by(buckets, fn bucket -> if usable?(bucket, task), do: elem(bucket, 1), else: 0 end)
  end

  defp usable?({_day, free} = bucket, %Task{} = task), do: free > 0 and startable?(bucket, task)

  # "Not before this day" applies inside the week too: an empty Monday is no use
  # to a task that was selected for Wednesday.
  defp startable?({day, _free}, %Task{planned_start_on: earliest}),
    do: not Date.before?(day, earliest)
end
