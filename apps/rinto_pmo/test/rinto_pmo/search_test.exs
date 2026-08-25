defmodule RintoPMO.SearchTest do
  use RintoPMO.DataCase, async: true

  import Hammox

  alias RintoPMO.AIMock
  alias RintoPMO.Annotations
  alias RintoPMO.Documents
  alias RintoPMO.Documents.DocumentBlock
  alias RintoPMO.References
  alias RintoPMO.Search
  alias RintoPMO.Tasks

  setup :verify_on_exit!

  defp vector, do: List.duplicate(0.1, 1024)

  # The service is mocked, so ordering is whatever the test says it is. What is
  # being checked here is the plumbing around the two calls -- scoping,
  # collapsing, and how a hit becomes an address -- not the model's judgement.
  defp expect_pipeline(rank_by \\ fn _text -> 0.5 end) do
    expect(AIMock, :embed_query, fn _query -> {:ok, vector()} end)

    expect(AIMock, :rerank, fn _query, documents ->
      {:ok,
       documents
       |> Enum.with_index()
       |> Enum.map(fn {text, index} -> %{index: index, score: rank_by.(text)} end)
       |> Enum.sort_by(& &1.score, :desc)}
    end)
  end

  defp embed_everything do
    for schema <- [DocumentBlock, Tasks.Task, RintoPMO.Projects.Project, Annotations.Annotation] do
      schema
      |> where([row], is_nil(row.embedding))
      |> Repo.update_all(set: [embedding: Pgvector.new(vector())])
    end
  end

  defp document_with(markdown, opts \\ []) do
    {:ok, document} =
      Documents.create_document(%{
        title: Keyword.get(opts, :title, "上线流程"),
        actor_id: insert(:actor).id,
        project_id: Keyword.get_lazy(opts, :project_id, fn -> insert(:project).id end),
        markdown: markdown
      })

    document
  end

  describe "the closed loop" do
    # The whole point of answering with a URI: whatever comes out has to go
    # straight back in, with nothing assembling an id from parts.
    test "every result's URI parses back to the resource that produced it" do
      document = document_with("## 部署步骤\n\n先确认 systemd unit")
      embed_everything()
      expect_pipeline()

      assert {:ok, [result]} = Search.search("部署", type: "block")

      assert {:ok, reference} = References.parse(result.uri)
      assert reference.type == "block"
      assert References.to_uri(reference) == result.uri
      assert result.document_id == document.id
    end
  end

  describe "what a type answers with" do
    setup do
      document = document_with("## 部署步骤\n\n先确认 systemd\n\n## 回滚\n\n按上一版重放")
      embed_everything()
      %{document: document}
    end

    test "block answers with the section that matched", %{document: document} do
      expect_pipeline()

      assert {:ok, results} = Search.search("部署", type: "block")
      assert length(results) == 2

      for result <- results do
        assert result.type == "block"
        assert String.starts_with?(result.uri, "rinto://block/")
        assert result.document_id == document.id
        assert result.document_title == "上线流程"
      end
    end

    # A document's content is its sections, so searching for a document means
    # searching its blocks and answering one level up.
    test "document collapses its sections into one result", %{document: document} do
      expect_pipeline()

      assert {:ok, [result]} = Search.search("部署", type: "document")
      assert result.uri == "rinto://document/#{document.id}"
      assert result.title == "上线流程"
    end

    test "a collapsed result keeps its best-scoring member's score", %{document: _document} do
      expect_pipeline(fn text -> if text =~ "回滚", do: 0.9, else: 0.1 end)

      assert {:ok, [result]} = Search.search("回滚", type: "document")
      assert result.score == 0.9
    end
  end

  # A reply is a search unit but never a result: what a reader wants is the
  # thread, which is what its annotation becomes.
  describe "annotations and their replies" do
    test "a reply that matches answers with its thread" do
      document = document_with("## 一\n\n内容")
      actor = insert(:actor)

      {:ok, annotation} =
        Annotations.create_annotation(document, %{actor_id: actor.id, content: "这里要改"})

      {:ok, _reply} =
        Annotations.create_reply(annotation, %{actor_id: actor.id, content: "改成 systemd 那句"})

      Annotations.AnnotationReply
      |> Repo.update_all(set: [embedding: Pgvector.new(vector())])

      embed_everything()
      expect_pipeline(fn text -> if text =~ "systemd", do: 0.9, else: 0.1 end)

      assert {:ok, [result]} = Search.search("systemd", type: "annotation")
      assert result.uri == "rinto://annotation/#{annotation.id}"
      assert result.score == 0.9
      assert result.document_id == document.id
    end
  end

  describe "scope" do
    test "project_id narrows before distance does" do
      wanted = insert(:project)
      other = insert(:project)

      document_with("## 部署\n\n要找的", project_id: wanted.id)
      document_with("## 部署\n\n不要的", project_id: other.id)
      embed_everything()
      expect_pipeline()

      assert {:ok, [result]} = Search.search("部署", type: "block", project_id: wanted.id)
      assert result.excerpt =~ "要找的"
    end

    # Unlike backlinks, which must answer completely: this question is "find me
    # something to use", and archived means "not in use".
    test "archived content is left out unless asked for" do
      document = document_with("## 部署\n\n归档的")
      embed_everything()

      # Nothing re-projects here, and nothing needs to: the flag is read from
      # the document by a join, so archiving takes effect the moment the row is
      # written. A copy of it on the projection is what used to need keeping up.
      {:ok, _archived} = Documents.archive_document(document)

      expect(AIMock, :embed_query, fn _query -> {:ok, vector()} end)
      assert {:ok, []} = Search.search("部署", type: "block")

      expect_pipeline()
      assert {:ok, [result]} = Search.search("部署", type: "block", include_archived: true)
      assert result.archived
    end
  end

  describe "rows without a vector" do
    test "do not participate" do
      document_with("## 部署步骤\n\n还没算向量")

      expect(AIMock, :embed_query, fn _query -> {:ok, vector()} end)

      assert {:ok, []} = Search.search("部署", type: "block")
    end
  end

  describe "types it will not search" do
    test "refuses one that is addressable but not indexed" do
      assert {:error, :unsearchable_type, details} = Search.search("x", type: "proposal")
      assert details.type == "proposal"
      assert "block" in details.searchable
    end

    test "refuses one this build has never heard of" do
      assert {:error, :unsearchable_type, _details} = Search.search("x", type: "intel")
    end

    # No default: a caller that has not said what it is looking for has not
    # decided, and picking for it would search one kind of thing while it
    # believed it was searching everything.
    test "refuses a request that names no type at all" do
      assert {:error, :unsearchable_type, %{type: nil}} = Search.search("部署")
    end

    test "lists what it will search" do
      types = Search.searchable_types()
      assert "block" in types
      assert "task" in types
      refute "proposal" in types
    end
  end

  describe "when the service is unavailable" do
    # Cosine order is the thing measured to be wrong, so handing it back
    # unranked would be answering with the failure mode reranking exists for.
    test "a failed rerank fails the search rather than degrading to cosine order" do
      document_with("## 部署\n\n内容")
      embed_everything()

      expect(AIMock, :embed_query, fn _query -> {:ok, vector()} end)
      expect(AIMock, :rerank, fn _query, _documents -> {:error, :not_configured} end)

      assert {:error, :ai_not_configured, %{}} = Search.search("部署", type: "block")
    end

    test "a failed query embedding fails the search" do
      expect(AIMock, :embed_query, fn _query -> {:error, {:transport, :econnrefused}} end)

      assert {:error, :ai_unavailable, %{reason: ":econnrefused"}} =
               Search.search("部署", type: "block")
    end

    # A server nobody gave a token to and a service that is down are different
    # problems with different fixes, so they are not the same error.
    test "a missing token is told apart from a service that answered badly" do
      expect(AIMock, :embed_query, fn _query -> {:error, :not_configured} end)
      assert {:error, :ai_not_configured, %{}} = Search.search("部署", type: "block")

      expect(AIMock, :embed_query, fn _query -> {:error, {:http, 502, "bad gateway"}} end)
      assert {:error, :ai_unavailable, %{status: 502}} = Search.search("部署", type: "block")
    end
  end

  describe "limits" do
    test "honours an explicit limit" do
      document_with("## 一\n\n甲\n\n## 二\n\n乙\n\n## 三\n\n丙")
      embed_everything()
      expect_pipeline()

      assert {:ok, results} = Search.search("x", type: "block", limit: 2)
      assert length(results) == 2
    end

    # The depth decides what the reranker is even shown, so it has to bind
    # before the ranking rather than after it. Asserted on what reaches the
    # reranker, not on the result count -- trimming afterwards would satisfy a
    # count and still have read the whole corpus.
    test "an explicit recall_limit is what reaches the reranker" do
      document_with("## 一\n\n甲\n\n## 二\n\n乙\n\n## 三\n\n丙")
      embed_everything()

      expect(AIMock, :embed_query, fn _query -> {:ok, vector()} end)

      expect(AIMock, :rerank, fn _query, documents ->
        assert length(documents) == 2

        {:ok, [%{index: 0, score: 0.9}, %{index: 1, score: 0.5}]}
      end)

      assert {:ok, results} = Search.search("x", type: "block", recall_limit: 2)
      assert length(results) == 2
    end

    test "recall_limit defaults to the configured depth" do
      document_with("## 一\n\n甲\n\n## 二\n\n乙\n\n## 三\n\n丙")
      embed_everything()

      expect(AIMock, :embed_query, fn _query -> {:ok, vector()} end)

      expect(AIMock, :rerank, fn _query, documents ->
        assert length(documents) == 3

        {:ok, Enum.map(0..2, &%{index: &1, score: 0.5})}
      end)

      assert {:ok, _results} = Search.search("x", type: "block")
    end

    # Refused rather than clamped: a caller comparing one depth against another
    # would otherwise draw its conclusion from a depth it did not ask for.
    test "refuses a recall_limit over the ceiling" do
      configured = Application.fetch_env!(:rinto_pmo, Search)[:max_recall_limit]

      assert {:error, :recall_limit_too_large, details} =
               Search.search("部署", type: "block", recall_limit: configured + 1)

      assert details.max == configured
      assert details.given == configured + 1
    end

    # Checked before the service is asked, so a request that was never going to
    # be served does not cost an embedding call. No `expect` for AIMock here:
    # calling it at all would fail the test.
    test "refuses the depth before embedding the query" do
      assert {:error, :recall_limit_too_large, _details} =
               Search.search("部署", type: "block", recall_limit: 10_000_000)
    end
  end
end
