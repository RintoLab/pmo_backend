defmodule Mix.Tasks.Rinto.Index.AuditTest do
  # Not async: the task writes to `Mix.shell()`, which is global.
  use RintoPMO.DataCase, async: false

  import Hammox

  alias Mix.Tasks.Rinto.Index.Audit
  alias RintoPMO.AIMock

  setup :verify_on_exit!

  setup do
    previous = Mix.shell()
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(previous) end)
    :ok
  end

  # Scores are dictated by the text so that a test says what it means: whatever
  # order the task hands documents over in, the block containing `marker` gets
  # `score`.
  defp expect_scores(probe_count, marked) do
    expect(AIMock, :rerank, probe_count, fn _query, documents ->
      {:ok,
       documents
       |> Enum.with_index()
       |> Enum.map(fn {text, index} ->
         score =
           Enum.find_value(marked, 0.01, fn {marker, s} -> String.contains?(text, marker) && s end)

         %{index: index, score: score}
       end)}
    end)
  end

  defp probes(queries) do
    path = Path.join(System.tmp_dir!(), "probes-#{System.unique_integer([:positive])}.txt")
    File.write!(path, Enum.join(queries, "\n"))
    on_exit(fn -> File.rm(path) end)
    path
  end

  defp block_with(content) do
    document = insert(:document)
    revision = insert(:document_revision, document: document, title: "试验文档")

    insert(:document_block,
      revision: revision,
      content: content,
      embedding: Pgvector.new(List.duplicate(0.1, 1024))
    )
  end

  defp run(argv) do
    Mix.Task.reenable("rinto.index.audit")
    Audit.run(argv)
  end

  defp output do
    receive do
      {:mix_shell, :info, [message]} -> message <> "\n" <> output()
      {:mix_shell, :error, [message]} -> message <> "\n" <> output()
    after
      0 -> ""
    end
  end

  # The whole point of the task: a block that scores well on *every*
  # unanswerable question, not one that spikes on a single question. Ranking by
  # mean would put the spike first, which is why the floor is the ranked number.
  test "ranks a block that answers everything above one that spikes once" do
    block_with("永远都很像的一段")
    block_with("只在一个问题上冒尖的一段")

    # Floors: 0.6 for the first, 0.01 for the second. Means: 0.6 and about 0.34,
    # so a mean-ranked report would still order them the same -- unless the
    # spike is big enough, which is what this sets up.
    expect(AIMock, :rerank, 2, fn query, documents ->
      {:ok,
       documents
       |> Enum.with_index()
       |> Enum.map(fn {text, index} ->
         score =
           cond do
             String.contains?(text, "永远") -> 0.6
             String.contains?(text, "冒尖") and query == "甲" -> 0.99
             true -> 0.01
           end

         %{index: index, score: score}
       end)}
    end)

    run(["--queries", probes(["甲", "乙"])])

    report = output()
    everything = index_of(report, "永远都很像的一段")
    spike = index_of(report, "只在一个问题上冒尖的一段")

    assert everything < spike,
           "expected the block with the higher floor first, got:\n#{report}"
  end

  test "reports the floor and the mean of each block it lists" do
    block_with("被打高分的一段")

    expect_scores(2, [{"被打高分", 0.8}])

    run(["--queries", probes(["甲", "乙"])])

    assert output() =~ "0.8"
  end

  test "counts every pair it asked about" do
    for content <- ["第一段", "第二段", "第三段"], do: block_with(content)

    expect_scores(2, [])

    run(["--queries", probes(["甲", "乙"])])

    assert output() =~ "6 (block, question) pairs"
  end

  # Batching exists to keep a request small; it must not change which block a
  # score belongs to. Two batches of one, scored by content, would silently
  # mis-attribute if the index were read against the wrong list.
  test "attributes scores correctly when the corpus is split across batches" do
    block_with("高分的一段")
    block_with("低分的一段")

    # Two probes over two batches of one: four calls, not two.
    expect_scores(4, [{"高分", 0.9}])

    run(["--queries", probes(["甲", "乙"]), "--batch", "1"])

    report = output()
    assert index_of(report, "高分的一段") < index_of(report, "低分的一段")
  end

  # A partial audit ranks blocks by a floor that was never established, which
  # reads as a clean result rather than a missing one.
  test "reports a failed call instead of an audit with holes in it" do
    block_with("一段")

    expect(AIMock, :rerank, fn _query, _documents -> {:error, :not_configured} end)

    run(["--queries", probes(["甲", "乙"])])

    report = output()
    assert report =~ "not_configured"
    refute report =~ "pairs"
  end

  test "says so when there is nothing embedded to audit" do
    run(["--queries", probes(["甲"])])

    assert output() =~ "nothing is embedded"
  end

  defp index_of(report, needle) do
    case :binary.match(report, needle) do
      {position, _length} -> position
      :nomatch -> flunk("#{needle} is missing from:\n#{report}")
    end
  end
end
