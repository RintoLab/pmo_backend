defmodule Mix.Tasks.Rinto.Index.Audit do
  @shortdoc "Finds blocks the reranker scores highly no matter what is asked"

  @moduledoc """
  Scores every searchable block against questions it cannot possibly answer.

      mix rinto.index.audit
      mix rinto.index.audit --queries probes.txt --top 20

  ## What this is looking for

  A block that scores highly on a question about braised pork is not a good
  answer to anything -- it is a block the reranker likes regardless of what was
  asked. One of those in the corpus outranks the real answer on every query it
  touches, and nothing in a search result says it happened: the answer that was
  pushed to second place still looks like a normal second place.

  This was found by hand once. The point of running it over the whole corpus is
  to learn whether that block was alone.

  ## Why the probes are off-topic on purpose

  The probes are questions from domains this system has no content about --
  cooking, medicine, travel. That is what makes the reading unambiguous: the
  correct score for every block against every probe is *approximately zero*, so
  a high score needs no judgement to interpret and no relevance labels to check
  against. An on-topic probe would need somebody to say whether a hit was fair.

  They are also unrelated to **each other**, so no block can legitimately be
  about more than one of them.

  ## The number that matters is the lowest one

  A block is ranked here by its **minimum** score across the probes -- how well
  it does on its worst question. A block that answers one probe strangely well
  is noise. A block whose *floor* is high answers everything, which is the
  failure being looked for.

  ## What it does not tell you

  Only whether the reranker has blocks it likes unconditionally. It says
  nothing about whether the reranker orders *real* queries correctly, which
  needs relevance judgements a machine cannot supply.

  It covers `document_blocks` only -- the largest searchable projection, and the
  one the failure was seen in. Tasks, annotations, projects and conversations
  are reranked by the same model and are not audited here.

  ## Cost

  One call per probe per batch of blocks: with the default probes and a corpus
  of a few hundred blocks, tens of calls. Scores do not depend on what else is
  in the batch, so batching changes nothing but the request size.
  """

  use Mix.Task

  import Ecto.Query

  alias RintoPMO.Documents.DocumentBlock
  alias RintoPMO.Documents.Revisions
  alias RintoPMO.Repo
  alias RintoPMO.Utils

  # Six domains this system holds nothing about, and which have nothing to do
  # with one another. Written in Chinese because the corpus is.
  @probes [
    "红烧肉要炖多久才入味",
    "高血压患者日常饮食要注意什么",
    "从上海到成都的高铁要坐几个小时",
    "钢琴考级八级有哪些曲目",
    "今年梅雨季节大概什么时候结束",
    "猫突然不吃东西可能是什么原因"
  ]

  # Kept well under the reranker's appetite: a hundred candidates has been seen
  # to take a service timeout, and a slower audit is better than a retried one.
  @batch_size 50

  @default_top 10

  @impl Mix.Task
  def run(argv) do
    Mix.Task.run("app.start")

    {opts, _rest} =
      OptionParser.parse!(argv, strict: [queries: :string, top: :integer, batch: :integer])

    probes = probes(opts[:queries])
    blocks = blocks()

    cond do
      probes == [] -> Mix.shell().error("no probe queries to ask")
      blocks == [] -> Mix.shell().error("nothing is embedded, so nothing is searchable")
      true -> audit(probes, blocks, opts)
    end
  end

  defp audit(probes, blocks, opts) do
    batch = Keyword.get(opts, :batch, @batch_size)

    Mix.shell().info(
      "asking #{length(probes)} off-topic questions of #{length(blocks)} blocks" <>
        " (#{length(probes) * ceil(length(blocks) / batch)} calls)\n"
    )

    case score_all(probes, blocks, batch) do
      {:ok, scored} -> report(scored, probes, Keyword.get(opts, :top, @default_top))
      {:error, reason} -> Mix.shell().error("the inference service said: #{inspect(reason)}")
    end
  end

  # One list of scores per block, in probe order. Stops at the first failure
  # rather than reporting an audit with holes in it -- a block missing its worst
  # probe would be ranked by a floor it never actually had.
  defp score_all(probes, blocks, batch) do
    Enum.reduce_while(probes, {:ok, %{}}, fn probe, {:ok, acc} ->
      case score_probe(probe, blocks, batch) do
        {:ok, scores} ->
          Mix.shell().info("  asked: #{probe}")
          {:cont, {:ok, Map.merge(acc, scores, fn _key, a, b -> a ++ b end)}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
  end

  defp score_probe(probe, blocks, batch) do
    blocks
    |> Enum.chunk_every(batch)
    |> Enum.reduce_while({:ok, %{}}, fn chunk, {:ok, acc} ->
      case Utils.module(:ai).rerank(probe, Enum.map(chunk, & &1.content)) do
        {:ok, rankings} -> {:cont, {:ok, Map.merge(acc, attribute(rankings, chunk))}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  # `index` is a position in the list that was handed over, which is this chunk
  # in this order. Attribution therefore has to be against the chunk and not
  # against the corpus -- reading it against the corpus would put every score
  # on the wrong block from the second batch onwards, and the report would look
  # exactly as plausible.
  defp attribute(rankings, chunk) do
    Map.new(rankings, fn %{index: index, score: score} ->
      {Enum.at(chunk, index).block_id, [score]}
    end)
  end

  defp report(scored, probes, top) do
    all = scored |> Map.values() |> List.flatten() |> Enum.sort()

    Mix.shell().info("""

    #{length(all)} (block, question) pairs, every one of which should score near zero:

      median #{fmt(percentile(all, 0.5))}   p90 #{fmt(percentile(all, 0.9))}   p99 #{fmt(percentile(all, 0.99))}   max #{fmt(List.last(all))}
    """)

    ranked =
      scored
      |> Enum.map(fn {block_id, scores} ->
        {block_id, Enum.min(scores), Enum.sum(scores) / length(scores)}
      end)
      |> Enum.sort_by(fn {_id, floor, _mean} -> floor end, :desc)
      |> Enum.take(top)

    titles = titles(Enum.map(ranked, fn {id, _floor, _mean} -> id end))

    Mix.shell().info(
      "the #{top} blocks with the highest floor" <>
        " -- \"even its worst of #{length(probes)} unanswerable questions scored this\":\n"
    )

    Mix.shell().info("  floor   mean    block")

    Enum.each(ranked, fn {block_id, floor, mean} ->
      Mix.shell().info("  #{fmt(floor)}  #{fmt(mean)}  #{Map.get(titles, block_id, block_id)}")
    end)

    Mix.shell().info("""

    A floor near zero is the whole corpus behaving. A floor that is not says
    that block answers questions it has no content about, and outranks the real
    answer whenever it is a candidate.
    """)
  end

  defp blocks do
    DocumentBlock
    # The same predicate `RintoPMO.Search` uses, so the audit covers exactly
    # what a search can return and nothing it cannot.
    |> where([block], not is_nil(block.embedding))
    |> join(:inner, [block], revision in subquery(Revisions.latest()),
      on: revision.id == block.revision_id
    )
    |> select([block], %{block_id: block.block_id, content: block.content})
    # `log: false` because this is a report someone reads: two query dumps
    # between the numbers and the table is noise in the middle of the answer.
    |> Repo.all(log: false)
  end

  defp titles(block_ids) do
    DocumentBlock
    |> where([block], block.block_id in ^block_ids)
    |> join(:inner, [block], revision in subquery(Revisions.latest()),
      on: revision.id == block.revision_id
    )
    |> select([block, revision], {block.block_id, revision.title, block.content})
    |> Repo.all(log: false)
    |> Map.new(fn {block_id, title, content} ->
      {block_id, "#{title} / #{content |> String.replace(~r/\s+/u, " ") |> String.slice(0, 40)}"}
    end)
  end

  defp probes(nil), do: @probes

  defp probes(path) do
    path
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp percentile([], _fraction), do: 0.0

  defp percentile(sorted, fraction) do
    Enum.at(sorted, min(round(fraction * length(sorted)), length(sorted) - 1))
  end

  defp fmt(number), do: number |> Kernel.*(1.0) |> Float.round(4) |> Float.to_string()
end
