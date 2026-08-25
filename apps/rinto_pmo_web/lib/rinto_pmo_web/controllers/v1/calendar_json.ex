defmodule RintoPMOWeb.V1.CalendarJSON do
  alias RintoPMO.Calendar.Day
  alias RintoPMO.Calendar.Import

  @doc """
  The exceptions in a span, and which years are actually behind them.

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

  defp data(%Day{} = day) do
    %{
      day: day.day,
      kind: day.kind,
      name: day.name,
      inserted_at: day.inserted_at,
      updated_at: day.updated_at
    }
  end

  # `updated_at` is when the year was last read, which matters as much as
  # whether it ever was: the State Council amends, and the importer runs daily
  # so that a year stays current rather than staying imported.
  defp import_data(%Import{} = import) do
    %{year: import.year, source: import.source, updated_at: import.updated_at}
  end
end
