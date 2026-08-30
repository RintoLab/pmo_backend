defmodule RintoPMOWeb.V1.CalendarJSON do
  alias RintoPMO.Calendar.Import
  alias RintoPMO.Calendar.Leave

  @doc """
  The days in a span that are not ordinary, and which years are behind them.

  `imports` is not decoration. A day missing from `days` means "ordinary" only
  for a year that appears here; for any other year it means nobody has looked,
  and every capacity figure in it came from the weekend rule alone.
  """
  def index(%{days: days, imports: imports}) do
    %{
      data: Enum.map(days, &data/1),
      imports: Enum.map(imports, &import_data/1)
    }
  end

  def show(%{day: day}), do: %{data: data(day)}

  # Two facts about a day, kept apart because they have different owners and
  # different answers. `kind` and `name` are the announcement's, null on a day
  # it said nothing about; `leave` is the person's, null when they are here.
  # They used to be one `kind` field with `leave` as a third value, which meant
  # a day could not be both -- and taking a make-up Saturday off erased the
  # fact that it had been one.
  #
  # The two capacities are derived, and both are given so that a client can
  # show the subtraction rather than reproduce it. `capacity_minutes` is the
  # number that matters: it is what `GET /schedule` packs against.
  defp data(view) do
    %{
      day: view.day,
      kind: view.base && view.base.kind,
      name: view.base && view.base.name,
      leave: leave_data(view.leave),
      base_capacity_minutes: view.base_capacity_minutes,
      capacity_minutes: view.capacity_minutes,
      inserted_at: view.base && view.base.inserted_at,
      updated_at: view.base && view.base.updated_at
    }
  end

  # `minutes` is what the person said, not what it came to. It can exceed the
  # day -- 1440 is the convention for a whole day off -- and a client showing it
  # against `base_capacity_minutes` is showing both halves of the comparison
  # that produced `capacity_minutes`.
  defp leave_data(nil), do: nil

  defp leave_data(%Leave{} = leave) do
    %{
      minutes: leave.minutes,
      name: leave.name,
      inserted_at: leave.inserted_at,
      updated_at: leave.updated_at
    }
  end

  # `updated_at` is when the year was last read, which matters as much as
  # whether it ever was: the State Council amends, and the importer runs daily
  # so that a year stays current rather than staying imported.
  defp import_data(%Import{} = import) do
    %{year: import.year, source: import.source, updated_at: import.updated_at}
  end
end
