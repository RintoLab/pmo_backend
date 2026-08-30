defmodule RintoPMO.Calendar do
  @moduledoc """
  Which days are worked, and how many minutes each one holds.

  Everything `RintoPMO.Schedule` knows about time comes from here, so that
  "when can work happen" stays one question with one answer rather than a
  weekend check copied into every query that needed one.

  ## An iteration is a week, and it is never stored

  A week is named by the Monday it starts on. That is the whole of it: there
  is no iterations table, because after dropping the project scope, the name,
  and the manual start and end dates, a row would hold nothing but its own
  primary key -- a table whose only job is to turn a value that is already
  unique into a uuid, and to add a join to every query that wanted the value.

  The week a task belongs to is therefore `monday_of/1` applied to a date, not
  a column, and "the current iteration" is `current_week/0`. There is nothing
  to close, nothing to open, and nothing that can disagree with the calendar.

  ## Load once, ask many times

  `capacity_on/2` reads two tables, and the packer asks it for every day of
  every week it plans. So the reads happen once, in `load/2`, and produce a
  value that answers the rest without touching the database again -- a
  year-long forecast is three queries rather than three hundred.

  The pure date arithmetic -- `monday_of/1`, `weeks/2`, `next_week/1` -- needs
  no data and takes none.

  ## The default is Monday to Friday, and the tables hold only departures

  `daily_capacity/0` is 480 minutes: eight hours. It is a constant rather than
  a setting, because `RintoPMO.Settings` is a table of which actor plays which
  role and says as much in its own first line.

  What varies is not the length of a working day but which days are worked,
  and `RintoPMO.Calendar.Day` holds exactly the days that depart from the
  default: statutory holidays and the weekends China works to make up for them.

  ## A day has a base, and leave comes off it

  Those two questions are asked in that order, and they are different
  questions. `workday?/2` and `base_capacity/2` are the calendar: is this a day
  work happens on at all, and how many minutes does it start with.
  `RintoPMO.Calendar.Leave` then subtracts, and `capacity_on/2` is what is
  actually left.

  They were one table and one question until leave could be partial, and the
  `20260830100000_leave_is_measured_in_minutes` migration has the account of
  what that cost -- an import that silently refused to write a holiday onto a
  day somebody had taken off, among other things.

  Subtraction is why leave carries no ceiling and no "all day" flag. Whether a
  number covers the whole day is a comparison, made here against what the day
  holds now, rather than a property frozen into the row when it was written.
  `max(base - minutes, 0)` is the whole of it. By convention a whole day is
  1440 minutes, which is a fact about calendar days rather than a copy of
  `daily_capacity/0`, and so stays true if that number ever moves.

  Leave on a day that holds nothing anyway -- a Sunday, a statutory holiday --
  is recorded and changes nothing. That is not a special case being tolerated:
  the two tables have separate lifecycles, and a holiday later amended into a
  make-up workday must find the leave still there.

  ## A year nobody has read is not an ordinary year

  `week_known?/2` is false for a week in a year that was never imported. The
  packer still plans it -- refusing to answer would be worse than answering
  with a caveat -- but says so, and a caller that presents a capacity figure
  without passing that on is presenting a guess as a fact.

  Which is the same rule the rest of this system runs on: a partial answer must
  never pass for a whole one, the way a summed estimate carries the count of
  what it had to skip.
  """

  use RintoPMO, :context

  alias Ecto.Changeset
  alias RintoPMO.Calendar.Day
  alias RintoPMO.Calendar.Import
  alias RintoPMO.Calendar.Leave

  @daily_capacity 480

  @typedoc """
  A week, named by the Monday it starts on.
  """
  @type week :: Date.t()

  @typedoc """
  The calendar over some span of days, read once.

  `exceptions` holds only the days that depart from the weekend rule.
  `leaves` is minutes off, by day, and is a separate map because it is a
  separate question: the first says what a day starts with, the second says
  what comes off it. `known_years` is the years that have actually been
  imported, which is what separates "no holidays" from "nobody looked".
  """
  @type t :: %__MODULE__{
          exceptions: %{Date.t() => Day.kind()},
          leaves: %{Date.t() => pos_integer()},
          known_years: MapSet.t(integer())
        }

  defstruct exceptions: %{}, leaves: %{}, known_years: MapSet.new()

  @typedoc """
  One day that is not ordinary, with everything needed to show it.

  `base` is the imported row and `leave` the person's, either of which may be
  absent -- a day appears at all because it has at least one of them. The two
  capacities are derived rather than stored: `base_capacity_minutes` is what
  the day starts with and `capacity_minutes` what is left, so a client can say
  "120 minutes off, 360 to work" without knowing the arithmetic.
  """
  @type day_view :: %{
          day: Date.t(),
          base: Day.t() | nil,
          leave: Leave.t() | nil,
          base_capacity_minutes: non_neg_integer(),
          capacity_minutes: non_neg_integer()
        }

  @doc """
  Reads the calendar covering every week from `from` through `to`.

  Whole weeks: the span is widened to the Monday of `from` and the Sunday of
  `to`, so a caller never has to think about where a week's edges fall.
  """
  @spec load(Date.t(), Date.t()) :: t()
  def load(%Date{} = from, %Date{} = to) do
    first = monday_of(from)
    last = Date.add(monday_of(to), 6)

    if Date.before?(last, first) do
      %__MODULE__{}
    else
      %__MODULE__{
        exceptions: read_exceptions(first, last),
        leaves: read_leaves(first, last),
        known_years: read_known_years(first.year, last.year)
      }
    end
  end

  @doc """
  An empty calendar: no exceptions, and no year known.

  For callers that have no span to read -- and a reminder that "empty" means
  every week is unknown rather than every week being ordinary.
  """
  @spec none() :: t()
  def none, do: %__MODULE__{}

  @doc """
  How many minutes of work a single workday holds.
  """
  @spec daily_capacity() :: pos_integer()
  def daily_capacity, do: @daily_capacity

  @doc """
  Whether work happens on `date` at all.

  Monday to Friday, unless the announcement says otherwise: a statutory holiday
  is not worked, and a make-up day is worked however the weekend rule feels
  about it.

  Leave is not part of this answer. A Wednesday somebody is away for the whole
  of is still a working Wednesday -- what changed is how many of its minutes
  are left, which is `capacity_on/2`.
  """
  @spec workday?(t(), Date.t()) :: boolean()
  def workday?(%__MODULE__{} = calendar, %Date{} = date) do
    case Map.get(calendar.exceptions, date) do
      :workday -> true
      :holiday -> false
      nil -> Date.day_of_week(date) <= 5
    end
  end

  @doc """
  How many minutes `date` holds before any leave comes off it.
  """
  @spec base_capacity(t(), Date.t()) :: non_neg_integer()
  def base_capacity(%__MODULE__{} = calendar, %Date{} = date),
    do: if(workday?(calendar, date), do: @daily_capacity, else: 0)

  @doc """
  How many minutes of work `date` actually holds.

  The base, less whatever leave was recorded, and never below zero. `max/2` is
  where "the whole day" is decided: leave of 1440 minutes -- or of any number
  at or above what the day holds -- leaves nothing, without the record having
  had to declare itself all-day when it was written.

  Leave on a day that holds nothing subtracts from nothing and is not an error.
  """
  @spec capacity_on(t(), Date.t()) :: non_neg_integer()
  def capacity_on(%__MODULE__{} = calendar, %Date{} = date),
    do: max(base_capacity(calendar, date) - Map.get(calendar.leaves, date, 0), 0)

  @doc """
  Whether the calendar covering `date` was ever actually read.

  False does not mean the day is unusable. It means the answer about it came
  from the weekend rule alone, and a week in China planned that way will have
  Spring Festival down as five ordinary working days.
  """
  @spec known?(t(), Date.t()) :: boolean()
  def known?(%__MODULE__{} = calendar, %Date{} = date),
    do: MapSet.member?(calendar.known_years, date.year)

  @doc """
  Whether every day of the week `date` falls in comes from a year that was read.

  A week can straddle New Year, so this is not one year's question.
  """
  @spec week_known?(t(), Date.t()) :: boolean()
  def week_known?(%__MODULE__{} = calendar, %Date{} = date) do
    monday = monday_of(date)

    Enum.all?(0..6, &known?(calendar, Date.add(monday, &1)))
  end

  @doc """
  The Monday of the week `date` falls in.

  This is how a date becomes an iteration, and the only place that conversion
  happens.
  """
  @spec monday_of(Date.t()) :: week()
  def monday_of(%Date{} = date), do: Date.beginning_of_week(date)

  @doc """
  The week that is running today.
  """
  @spec current_week() :: week()
  def current_week, do: monday_of(Date.utc_today())

  @doc """
  The week after `week`.
  """
  @spec next_week(week()) :: week()
  def next_week(%Date{} = week), do: Date.add(monday_of(week), 7)

  @doc """
  Every week from `from` through `to`, inclusive, earliest first.

  Empty when `to` is before `from`, so a caller that asks for a backwards range
  gets nothing rather than an infinite walk.
  """
  @spec weeks(week(), week()) :: [week()]
  def weeks(%Date{} = from, %Date{} = to) do
    from = monday_of(from)
    to = monday_of(to)

    if Date.before?(to, from) do
      []
    else
      from
      |> Stream.iterate(&next_week/1)
      |> Enum.take_while(&(not Date.after?(&1, to)))
    end
  end

  @doc """
  The workdays in the week `date` falls in, earliest first.

  The announcement's answer, before leave: a day somebody is away for the whole
  of is in this list, holding zero minutes. Ask `capacities_in/2` for the days
  work can actually go into.

  A week with none is an ordinary answer, not an error: a week that is entirely
  holiday holds no work, and everything selected into it will say so by failing
  to fit.
  """
  @spec workdays_in(t(), Date.t()) :: [Date.t()]
  def workdays_in(%__MODULE__{} = calendar, %Date{} = date) do
    monday = monday_of(date)

    0..6
    |> Enum.map(&Date.add(monday, &1))
    |> Enum.filter(&workday?(calendar, &1))
  end

  @doc """
  The days of the week `date` falls in that hold any minutes, with how many.

  Earliest first, and days holding nothing are left out entirely rather than
  carried as zeroes -- a day taken off in full is not somewhere work can be put,
  and a caller folding over this should not have to remember that.
  """
  @spec capacities_in(t(), Date.t()) :: [{Date.t(), pos_integer()}]
  def capacities_in(%__MODULE__{} = calendar, %Date{} = date) do
    monday = monday_of(date)

    0..6
    |> Enum.map(&Date.add(monday, &1))
    |> Enum.map(&{&1, capacity_on(calendar, &1)})
    |> Enum.reject(fn {_day, minutes} -> minutes == 0 end)
  end

  @doc """
  How many minutes of work the week `date` falls in can hold.

  Leave included: this is what the week has left, not what the announcement
  would have given it.
  """
  @spec week_capacity(t(), Date.t()) :: non_neg_integer()
  def week_capacity(%__MODULE__{} = calendar, %Date{} = date),
    do: calendar |> capacities_in(date) |> Enum.sum_by(fn {_day, minutes} -> minutes end)

  @doc """
  Records how many minutes of `day` a person is away for.

  Idempotent on the date: asking twice replaces rather than accumulates, so a
  correction is a second `PUT` and not a sum of every time somebody changed
  their mind.

  Nothing in the calendar is touched. Being away on a day that was already off
  is not a conflict and not an overwrite -- the leave is recorded, subtracts
  from a day that holds nothing, and is still there if that day is later
  amended into one that does.

  `minutes` has no ceiling. See `RintoPMO.Calendar.Leave`.
  """
  @spec put_leave(Date.t(), pos_integer(), String.t() | nil) ::
          {:ok, Leave.t()} | {:error, Changeset.t()}
  def put_leave(%Date{} = day, minutes, name \\ nil) do
    %{day: day, minutes: minutes, name: name}
    |> Leave.changeset()
    |> Repo.insert(
      on_conflict: {:replace, [:minutes, :name, :updated_at]},
      conflict_target: :day
    )
  end

  @doc """
  Removes a day of leave.

  A holiday is not a person's to delete, and this cannot reach one: they are
  different tables now. The day goes back to whatever the announcement says
  about it, which is the thing the single-table version could not do.
  """
  @spec delete_leave(Date.t()) :: :ok
  def delete_leave(%Date{} = day) do
    Leave
    |> where([leave], leave.day == ^day)
    |> Repo.delete_all()

    :ok
  end

  @doc """
  Every day between two dates that is not ordinary, earliest first.

  A day is here because the announcement said something about it, or because
  somebody is away for part of it, or both. Each entry carries what the day
  starts with and what is left of it, so that "which of these two facts made
  this day short" is answerable without a second request.
  """
  @spec list_days(Date.t(), Date.t()) :: [day_view()]
  def list_days(%Date{} = from, %Date{} = to) do
    bases = from |> read_days(to) |> Map.new(&{&1.day, &1})
    leaves = from |> read_leave_rows(to) |> Map.new(&{&1.day, &1})

    calendar = %__MODULE__{
      exceptions: Map.new(bases, fn {day, base} -> {day, base.kind} end),
      leaves: Map.new(leaves, fn {day, leave} -> {day, leave.minutes} end)
    }

    bases
    |> Map.keys()
    |> Enum.concat(Map.keys(leaves))
    |> Enum.uniq()
    |> Enum.sort(Date)
    |> Enum.map(&view(calendar, &1, bases, leaves))
  end

  @doc """
  One day, whether or not anything was ever recorded about it.

  Unlike `list_days/2` this always answers: a day nobody has touched is an
  ordinary one, and saying so is more useful to a caller that just wrote to it
  than an empty list would be.
  """
  @spec get_day(Date.t()) :: day_view()
  def get_day(%Date{} = day) do
    case list_days(day, day) do
      [view] -> view
      [] -> view(none(), day, %{}, %{})
    end
  end

  defp view(calendar, day, bases, leaves) do
    %{
      day: day,
      base: Map.get(bases, day),
      leave: Map.get(leaves, day),
      base_capacity_minutes: base_capacity(calendar, day),
      capacity_minutes: capacity_on(calendar, day)
    }
  end

  @doc """
  Replaces a year's imported days, and records that the year was read.

  `days` is `{date, :holiday | :workday, name}` triples.

  Delete-and-rewrite rather than a diff, for the reason `RintoPMO.Links` gives
  for the same choice: whatever went wrong last time is gone the next time the
  source is read. It takes the whole year, unbounded by kind, because every row
  in this table is now an import's: leave lives elsewhere and is out of reach
  by construction rather than by a `where` clause somebody has to keep right.

  Which also lets the insert be a plain one. It used to skip conflicts, and
  since a leave row could occupy the date, that quietly dropped holidays --
  after the delete there is nothing left to conflict with except the same date
  arriving twice from the source, which should fail the year rather than lose a
  day out of it.

  One transaction. A year that is half-rewritten is a year whose capacity is
  wrong in a way nobody would think to look for.
  """
  @spec import_year(integer(), String.t(), [{Date.t(), Day.kind(), String.t() | nil}]) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def import_year(year, source, days) when is_integer(year) and is_list(days) do
    first = Date.new!(year, 1, 1)
    last = Date.new!(year, 12, 31)
    now = DateTime.utc_now()

    rows =
      Enum.map(days, fn {%Date{} = day, kind, name} ->
        %{day: day, kind: kind, name: name, inserted_at: now, updated_at: now}
      end)

    Repo.transaction(fn ->
      Day
      |> where([calendar_day], calendar_day.day >= ^first and calendar_day.day <= ^last)
      |> Repo.delete_all()

      {count, _} = Repo.insert_all(Day, rows)

      %{year: year, source: source}
      |> Import.changeset()
      |> Repo.insert!(
        on_conflict: {:replace, [:source, :updated_at]},
        conflict_target: :year
      )

      count
    end)
  end

  @doc """
  The years that have been read, and when.
  """
  @spec list_imports() :: [Import.t()]
  def list_imports do
    Import |> order_by([import], asc: import.year) |> Repo.all()
  end

  defp read_exceptions(first, last) do
    Day
    |> where([calendar_day], calendar_day.day >= ^first and calendar_day.day <= ^last)
    |> select([calendar_day], {calendar_day.day, calendar_day.kind})
    |> Repo.all()
    |> Map.new()
  end

  defp read_leaves(first, last) do
    Leave
    |> where([leave], leave.day >= ^first and leave.day <= ^last)
    |> select([leave], {leave.day, leave.minutes})
    |> Repo.all()
    |> Map.new()
  end

  defp read_days(first, last) do
    Day
    |> where([calendar_day], calendar_day.day >= ^first and calendar_day.day <= ^last)
    |> order_by([calendar_day], asc: calendar_day.day)
    |> Repo.all()
  end

  defp read_leave_rows(first, last) do
    Leave
    |> where([leave], leave.day >= ^first and leave.day <= ^last)
    |> order_by([leave], asc: leave.day)
    |> Repo.all()
  end

  defp read_known_years(first_year, last_year) do
    years = Enum.to_list(first_year..last_year)

    Import
    |> where([import], import.year in ^years)
    |> select([import], import.year)
    |> Repo.all()
    |> MapSet.new()
  end
end
