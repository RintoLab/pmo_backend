defmodule Mix.Tasks.Rinto.Links.Rebuild do
  @shortdoc "Reads the rinto:// reference index back out of every body"

  @moduledoc """
  Empties the `links` index and rebuilds it from the text it is derived from.

      mix rinto.links.rebuild

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

  One transaction, so a run that dies leaves the index it found rather than half
  of a new one.
  """

  use Mix.Task

  alias RintoPMO.Links

  @impl Mix.Task
  def run(_argv) do
    Mix.Task.run("app.start")

    tally = Links.rebuild()

    Mix.shell().info("""
    document blocks:   #{tally["document_block"]}
    annotations:       #{tally["annotation"]}
    annotation replies: #{tally["annotation_reply"]}
    tasks:             #{tally["task"]}
    messages:          #{tally["message"]}
    """)
  end
end
