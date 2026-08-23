defmodule Mix.Tasks.Rinto.Index.Rebuild do
  @shortdoc "Rebuilds the reference and discovery indexes from content"

  @moduledoc """
  Empties the reference and discovery indexes and rebuilds both from the
  content they are derived from.

      mix rinto.index.rebuild

  Three jobs, all the same job:

    * **backfill** -- bodies written before the index existed have references in
      them that nothing ever read
    * **repair** -- a write path that forgets to sync leaves stale or missing
      rows, and this is the answer rather than an incident
    * **proof** -- "the index is not the truth, it can be rebuilt from the
      content" is a claim the design leans on heavily. Running this is how that
      claim is checked instead of believed

  Safe to run repeatedly: the index is emptied first, so a second run over
  unchanged content produces exactly the same rows.

  Only the newest revision of each document is read, matching what the live
  write path indexes -- see `RintoPMO.Links.Link` on why history is not indexed.

  Named for the indexes rather than for `links` alone: it rebuilds both, and a
  name that mentioned one of them would be a standing invitation to forget the
  other.

  One transaction, so a run that dies leaves the index it found rather than half
  of a new one.
  """

  use Mix.Task

  alias RintoPMO.ContentIndex

  @impl Mix.Task
  def run(_argv) do
    Mix.Task.run("app.start")

    tally = ContentIndex.rebuild()

    Mix.shell().info("""
    documents:   #{tally["document"]}
    annotations: #{tally["annotation"]}
    tasks:       #{tally["task"]}
    messages:    #{tally["message"]}
    """)
  end
end
