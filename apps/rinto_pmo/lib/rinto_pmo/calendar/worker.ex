defmodule RintoPMO.Calendar.Worker do
  @moduledoc """
  Keeps the holiday calendar following the announcements it came from.

  ## This year and next, every day

  Two years, because planning runs forward: a forecast reaching into January
  needs next year's calendar, and next year's arrangement is published in
  November. Asking for it before then gets a `404`, which is *not* a failure --
  it is "not announced yet", and it stops being the answer on its own.

  Every day, because the State Council amends. A year read once in January is
  not the same as a year read this morning, and `calendar_imports.updated_at`
  is where the difference shows.

  ## One bad year does not sink the other

  Each year is fetched and imported on its own. A transport error on next year
  must not cost this year its refresh, so failures are logged and the job still
  succeeds -- there is nothing to retry that the next tick will not do anyway,
  and a retry storm against a raw file host helps nobody.

  A fetch that fails writes nothing, which leaves the last good import in place.
  That is the whole degradation story: the calendar gets older, never emptier.
  """

  use Oban.Worker,
    queue: :default,
    max_attempts: 1,
    unique: [period: 3600, states: :incomplete]

  alias RintoPMO.Calendar
  alias RintoPMO.Utils

  require Logger

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    year = Date.utc_today().year

    Enum.each([year, year + 1], &import_year/1)

    :ok
  end

  defp import_year(year) do
    case holidays().fetch(year) do
      # An empty year has not been announced, it is not a year without
      # holidays -- China has never had one of those, and the source publishes
      # the file before the State Council publishes the arrangement. Importing
      # it would mark the year *known* while knowing nothing about it, which is
      # precisely the silent wrongness `calendar_imports` exists to prevent,
      # arriving through the front door instead of the back.
      {:ok, %{days: []}} ->
        :ok

      {:ok, %{source: source, days: days}} ->
        write(year, source, days)

      # The ordinary state of affairs for next year until November. Nothing to
      # report: saying it daily would train whoever reads the log to skip it.
      {:error, :not_found} ->
        :ok

      {:error, reason} ->
        Logger.warning("calendar: could not read #{year}: #{inspect(reason)}")
    end
  end

  defp write(year, source, days) do
    case Calendar.import_year(year, source, days) do
      {:ok, count} ->
        Logger.info("calendar: #{year} has #{count} exceptions")

      {:error, reason} ->
        Logger.warning("calendar: could not write #{year}: #{inspect(reason)}")
    end
  end

  defp holidays, do: Utils.module(:holidays)
end
