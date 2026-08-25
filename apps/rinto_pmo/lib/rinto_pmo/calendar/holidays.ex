defmodule RintoPMO.Calendar.Holidays do
  @moduledoc """
  Reads one year of China's statutory holidays from `holiday-cn`.

  ## Fetched at runtime, not vendored

  The obvious alternative is to check the JSON into `priv/` and update it once
  a year. That was rejected, and not because fetching is cheaper: a vendored
  file **goes stale silently**. The State Council publishes the next year's
  arrangement in November; miss that and the system counts the October holiday
  as seven working days, inflating a week's capacity by thousands of minutes
  with nothing anywhere reporting a problem.

  A failed fetch is visible. A stale file is not. By the standard the rest of
  this system holds itself to -- a partial answer must never pass for a whole
  one -- the invisible failure is the worse one.

  The network dependency is not a new risk here either: this application
  already needs the network for everything it asks a model.

  ## Fetched into a table, not into a query

  Nothing reads this at the moment somebody asks about a week. The worker
  writes `calendar_days`, and every capacity figure is answered from there.
  A fetch that fails leaves the last good data in place, so the degradation is
  "this is a few days old" rather than "there is no calendar".

  ## Daily, because announcements are amended

  `holiday-cn` scrapes daily for that reason, and a one-shot import at the top
  of the year would keep whatever it happened to catch.

  ## `isOffDay` is both kinds

  One boolean carries the two exceptions that matter: `true` is a statutory
  day off, `false` is the Saturday or Sunday worked to make up for one. That
  is why `RintoPMO.Calendar.Day` holds them in a single table.
  """

  @behaviour RintoPMO.Calendar.Holidays.Behaviour

  @base_url "https://raw.githubusercontent.com/NateScarlet/holiday-cn/master"

  defmodule Behaviour do
    @moduledoc """
    One year of holidays, fetched.

    Exists so that the worker, the import, and the "this year was never read"
    guard are all testable without reaching the network.
    """

    @type day :: {Date.t(), :holiday | :workday, String.t() | nil}
    @type result :: %{source: String.t(), days: [day()]}
    @type error :: :not_found | {:http, pos_integer()} | {:transport, term()} | :invalid_payload

    @callback fetch(year :: integer()) :: {:ok, result()} | {:error, error()}
  end

  @doc """
  Fetches one year.

  `{:error, :not_found}` is the ordinary answer for a year that has not been
  announced yet, and callers are expected to treat it as "not yet" rather than
  as a failure.
  """
  @impl Behaviour
  @spec fetch(integer()) :: {:ok, Behaviour.result()} | {:error, Behaviour.error()}
  def fetch(year) when is_integer(year) do
    url = url(year)

    case Req.get(url, receive_timeout: 30_000, retry: :transient) do
      {:ok, %{status: 200, body: body}} -> read(body, url)
      {:ok, %{status: 404}} -> {:error, :not_found}
      {:ok, %{status: status}} -> {:error, {:http, status}}
      {:error, reason} -> {:error, {:transport, reason}}
    end
  end

  @doc """
  Where a year is read from.
  """
  @spec url(integer()) :: String.t()
  def url(year) when is_integer(year), do: "#{@base_url}/#{year}.json"

  @doc """
  Turns a response body into the days an import wants.

  Takes the raw string as well as a decoded map, because **the raw string is
  what actually arrives**: `raw.githubusercontent.com` serves `.json` as
  `text/plain`, so no HTTP client decodes it on the way past. Accepting only
  the decoded form is a parser that passes every test against a fixture and
  fails against the server.

  Public because it is the part most likely to be wrong when the source
  changes shape, and a private function reached through a stubbed HTTP client
  is tested one layer away from the thing that would actually break.

  **All or nothing.** One unreadable entry fails the whole year, because
  `RintoPMO.Calendar.import_year/3` deletes before it writes: half a parse
  would replace a good calendar with a broken one, and a year missing its
  Spring Festival is worse than a year that failed to refresh.
  """
  @spec days_from(term()) :: {:ok, [Behaviour.day()]} | {:error, :invalid_payload}
  def days_from(body) when is_binary(body) do
    case JSON.decode(body) do
      {:ok, decoded} -> days_from(decoded)
      {:error, _reason} -> {:error, :invalid_payload}
    end
  end

  def days_from(%{"days" => days}) when is_list(days) do
    parsed = Enum.map(days, &day/1)

    if Enum.any?(parsed, &(&1 == :error)) do
      {:error, :invalid_payload}
    else
      {:ok, parsed}
    end
  end

  def days_from(_body), do: {:error, :invalid_payload}

  defp read(body, url) do
    with {:ok, days} <- days_from(body) do
      {:ok, %{source: url, days: days}}
    end
  end

  defp day(%{"date" => date, "isOffDay" => off?} = entry) when is_boolean(off?) do
    case Date.from_iso8601(date) do
      {:ok, day} -> {day, if(off?, do: :holiday, else: :workday), entry["name"]}
      {:error, _reason} -> :error
    end
  end

  defp day(_entry), do: :error
end
