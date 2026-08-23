defmodule Mix.Tasks.Rinto.Index.Embed do
  @shortdoc "Computes the embeddings that are still missing, now"

  @moduledoc """
  Asks for an embedding pass immediately instead of on the next tick.

      mix rinto.index.embed

  **This is not a backfill task**, because there is nothing to backfill: a row
  with no vector is already the queue, and `RintoPMO.Embeddings.Worker` is
  already going to pick it up. All this does is skip the wait, which is worth
  having after a bulk import or a `mix rinto.index.rebuild`, when the backlog is
  thousands of rows and nobody wants to watch it drain fifteen seconds at a
  time.

  Safe to run repeatedly and safe to run while a pass is going: the worker
  deduplicates, so a second request while one is pending does nothing.

  It returns as soon as the pass is queued. Watch progress by counting the rows
  that are still waiting.
  """

  use Mix.Task

  alias RintoPMO.Embeddings.Worker

  @impl Mix.Task
  def run(_argv) do
    Mix.Task.run("app.start")

    case Worker.enqueue(0) do
      {:ok, %Oban.Job{conflict?: true}} ->
        Mix.shell().info("a pass is already pending; nothing to add")

      {:ok, _job} ->
        Mix.shell().info("pass queued")

      {:error, reason} ->
        Mix.shell().error("could not queue a pass: #{inspect(reason)}")
    end
  end
end
