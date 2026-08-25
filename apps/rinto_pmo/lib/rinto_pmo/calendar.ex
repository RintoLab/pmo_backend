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

  `workday?/2` reads a table, and the packer asks it for every day of every
  week it plans. So the reads happen once, in `load/2`, and produce a value
  that answers the rest without touching the database again -- a year-long
  forecast is two queries rather than three hundred.

  The pure date arithmetic -- `monday_of/1`, `weeks/2`, `next_week/1` -- needs
  no data and takes none.

  ## The default is Monday to Friday, and the table holds only departures

  `daily_capacity/0` is 480 minutes: eight hours. It is a constant rather than
  a setting, because `RintoPMO.Settings` is a table of which actor plays which
  role and says as much in its own first line.

  What varies is not the length of a working day but which days are worked,
  and `RintoPMO.Calendar.Day` holds exactly the days that depart from the
  default: statutory holidays, the weekends China works to make up for them,
  and time off.

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

  @daily_capacity 480

  @typedoc """
  A week, named by the Monday it starts on.
  """
  @type week :: Date.t()

  @typedoc """
  The calendar over some span of days, read once.

  `exceptions` holds only the days that depart from the weekend rule.
  `known_years` is the years that have actually been imported, which is what
  separates "no holidays" from "nobody looked".
  """
  @type t :: %__MODULE__{
          exceptions: %{Date.t() => Day.kind()},
          known_years: MapSet.t(integer())
        }

  defstruct exceptions: %{}, known_years: MapSet.new()

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
  Whether work happens on `date`.

  Monday to Friday, unless the day says otherwise: a statutory holiday and a
  day of leave are both not worked, and a make-up day is worked however the
  weekend rule feels about it.
  """
  @spec workday?(t(), Date.t()) :: boolean()
  def workday?(%__MODULE__{} = calendar, %Date{} = date) do
    case Map.get(calendar.exceptions, date) do
      :workday -> true
      :holiday -> false
      :leave -> false
      nil -> Date.day_of_week(date) <= 5
    end
  end

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
  How many minutes of work the week `date` falls in can hold.
  """
  @spec week_capacity(t(), Date.t()) :: non_neg_integer()
  def week_capacity(%__MODULE__{} = calendar, %Date{} = date),
    do: length(workdays_in(calendar, date)) * @daily_capacity

  @doc """
  Records that a person is away on `day`.

  Overwrites whatever was there, including an imported holiday: being away on
  a day that was already a day off is not a conflict, and the row that wins is
  the one a person wrote.
  """
  @spec put_leave(Date.t(), String.t() | nil) :: {:ok, Day.t()} | {:error, Changeset.t()}
  def put_leave(%Date{} = day, name \\ nil) do
    %{day: day, name: name}
    |> Day.leave_changeset()
    |> Repo.insert(
      on_conflict: {:replace, [:kind, :name, :updated_at]},
      conflict_target: :day
    )
  end

  @doc """
  Removes a day of leave.

  Only a `leave` row: a holiday is not a person's to delete, and the next
  import would put it back anyway.
  """
  @spec delete_leave(Date.t()) :: :ok
  def delete_leave(%Date{} = day) do
    Day
    |> where([calendar_day], calendar_day.day == ^day and calendar_day.kind == :leave)
    |> Repo.delete_all()

    :ok
  end

  @doc """
  Every exception between two dates, earliest first.
  """
  @spec list_days(Date.t(), Date.t()) :: [Day.t()]
  def list_days(%Date{} = from, %Date{} = to) do
    Day
    |> where([calendar_day], calendar_day.day >= ^from and calendar_day.day <= ^to)
    |> order_by([calendar_day], asc: calendar_day.day)
    |> Repo.all()
  end

  @doc """
  Replaces a year's imported days, and records that the year was read.

  `days` is `{date, :holiday | :workday, name}` triples.

  Delete-and-rewrite rather than a diff, for the reason `RintoPMO.Links` gives
  for the same choice: whatever went wrong last time is gone the next time the
  source is read. The delete is bounded to `Day.imported_kinds/0`, so a
  person's leave survives every import -- the two kinds share a table because
  capacity asks them the same question, not because an import owns them both.

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
      |> where([calendar_day], calendar_day.kind in ^Day.imported_kinds())
      |> Repo.delete_all()

      {count, _} = Repo.insert_all(Day, rows, on_conflict: :nothing, conflict_target: :day)

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

  defp read_known_years(first_year, last_year) do
    years = Enum.to_list(first_year..last_year)

    Import
    |> where([import], import.year in ^years)
    |> select([import], import.year)
    |> Repo.all()
    |> MapSet.new()
  end
end
