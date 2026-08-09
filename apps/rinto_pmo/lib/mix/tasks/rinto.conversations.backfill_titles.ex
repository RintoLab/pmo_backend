defmodule Mix.Tasks.Rinto.Conversations.BackfillTitles do
  @shortdoc "Names conversations that were left unnamed"

  @moduledoc """
  Names topics that existed before naming did.

      mix rinto.conversations.backfill_titles [--dry-run] [--limit N] [--concurrency N]

  Only topics that are unnamed, unclaimed and have at least one user message
  are touched -- the same test a live conversation passes (see
  `RintoPMO.Conversations.Titles`), so this can be run repeatedly, and running
  it twice over the same rows changes nothing the second time.

  An empty topic is left alone: there is nothing to name it after. A topic
  somebody named, or deliberately un-named, is left alone: that is a decision,
  and this task does not have a better one.

  ## Ordering is not disturbed

  Titles are written without touching `updated_at`, which the conversation list
  is ordered by. A backfill over a year of topics would otherwise reorder
  everybody's list into the order this task happened to run in, which is the
  one thing worse than a list of "未命名话题".

  ## Options

    * `--dry-run` -- report how many topics would be named and stop
    * `--limit` -- name at most this many, for a first cautious run
    * `--concurrency` -- naming calls in flight, default 2. Each is a model
      request, and the providers this ends up talking to are the same ones
      serving live conversations
  """

  use Mix.Task

  alias RintoPMO.Conversations.Titles

  @impl Mix.Task
  def run(argv) do
    {opts, _rest, _invalid} =
      OptionParser.parse(argv,
        strict: [dry_run: :boolean, limit: :integer, concurrency: :integer]
      )

    Mix.Task.run("app.start")

    pending = Titles.pending(opts[:limit])
    Mix.shell().info("#{length(pending)} conversation(s) to name")

    if opts[:dry_run] do
      :ok
    else
      pending |> name_all(Keyword.get(opts, :concurrency, 2)) |> report()
    end
  end

  # `:infinity` per element rather than a timeout: a naming call already has one
  # of its own (see `RintoPMO.Agent.TitleGenerator`), and a second deadline here
  # would abandon calls that are about to succeed.
  defp name_all(ids, concurrency) do
    ids
    |> Task.async_stream(&name/1, max_concurrency: concurrency, timeout: :infinity)
    |> Enum.reduce(%{model: 0, fallback: 0, skipped: 0, failed: 0}, fn
      {:ok, outcome}, tally -> Map.update!(tally, outcome, &(&1 + 1))
      {:exit, _reason}, tally -> Map.update!(tally, :failed, &(&1 + 1))
    end)
  end

  # One row that cannot be named must not end the run: the next thousand are
  # probably fine, and the failure is visible in the tally either way.
  defp name(id) do
    case Titles.name(id) do
      {:ok, _conversation, source} -> source
      _ignore_or_stale -> :skipped
    end
  rescue
    error ->
      Mix.shell().error("conversation #{id}: #{Exception.message(error)}")
      :failed
  end

  defp report(tally) do
    Mix.shell().info("""
    named by model:    #{tally.model}
    named by fallback: #{tally.fallback}
    skipped:           #{tally.skipped}
    failed:            #{tally.failed}
    """)
  end
end
