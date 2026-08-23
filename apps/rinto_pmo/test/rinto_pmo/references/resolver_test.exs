defmodule RintoPMO.References.ResolverTest do
  use RintoPMO.DataCase, async: true

  alias RintoPMO.References
  alias RintoPMO.References.Resolver

  defp uri(type, key), do: "rinto://#{type}/#{key}"

  defp resolve_one(uri) do
    assert {:ok, [resolved]} = Resolver.resolve([uri])
    resolved
  end

  # A document's title lives on its latest revision, so a document only really
  # exists here once it has one.
  defp document_with(title, opts \\ []) do
    document = insert(:document, archived_at: Keyword.get(opts, :archived_at))
    revision = insert(:document_revision, document: document, title: title)
    {document, revision}
  end

  describe "resolve/1 states" do
    test "resolves a task that is there" do
      task = insert(:task, title: "接入 r-nacos", description: "先确认 systemd unit", status: :open)

      assert %{state: :ok, type: "task", title: "接入 r-nacos"} =
               resolved = resolve_one(uri("task", task.id))

      assert resolved.subtitle == "open"
      assert resolved.excerpt == "先确认 systemd unit"
      refute resolved.archived
    end

    test "reports a known type that is not there as broken" do
      assert %{state: :broken, type: "task", title: nil} =
               resolve_one(uri("task", UUIDv7.generate()))
    end

    test "reports a type this build does not know, without failing" do
      assert %{state: :unknown_type, type: "intel", title: nil} =
               resolve_one(uri("intel", "anything"))
    end

    test "reports a malformed URI as invalid rather than broken" do
      assert %{state: :invalid, type: nil} = resolve_one("rinto://task/not-a-uuid")
      assert %{state: :invalid, type: nil} = resolve_one("https://example.test")
      assert %{state: :invalid, type: nil} = resolve_one("rinto://block:0193abc")
    end

    # The distinction the client renders on: one says the thing was deleted,
    # the other says the address was never any good.
    test "keeps broken and invalid apart" do
      assert {:ok, [broken, invalid]} =
               Resolver.resolve([uri("task", UUIDv7.generate()), "rinto://task/nope"])

      assert broken.state == :broken
      assert invalid.state == :invalid
    end
  end

  describe "resolve/1 per type" do
    test "project is addressed by slug" do
      project = insert(:project, name: "基础设施", slug: "infra", description: "机器与部署")

      assert %{state: :ok, title: "基础设施", excerpt: "机器与部署"} =
               resolve_one(uri("project", project.slug))

      assert %{state: :broken} = resolve_one(uri("project", "no-such-slug"))
    end

    test "document takes its title from the latest revision" do
      {document, first} = document_with("旧标题")
      insert_revision_after(first, document: document, title: "新标题")

      assert %{state: :ok, title: "新标题", subtitle: "draft"} =
               resolve_one(uri("document", document.id))
    end

    test "block carries the document it is in" do
      {document, revision} = document_with("上线流程")

      block =
        insert(:document_block,
          revision: revision,
          content: "## 部署步骤\n\n先确认 systemd unit"
        )

      resolved = resolve_one(uri("block", block.block_id))

      assert resolved.state == :ok
      assert resolved.title == "部署步骤"
      assert resolved.document_id == document.id
      assert resolved.document_title == "上线流程"
      assert resolved.excerpt =~ "systemd unit"
    end

    test "annotation and proposal carry their document" do
      {document, revision} = document_with("上线流程")
      annotation = insert(:annotation, document: document, content: "这里要补一句")

      proposal =
        insert(:block_proposal,
          document: document,
          base_revision: revision,
          content: "补上的那句"
        )

      assert %{state: :ok, document_title: "上线流程", excerpt: "这里要补一句"} =
               resolve_one(uri("annotation", annotation.id))

      assert %{state: :ok, document_title: "上线流程", excerpt: "补上的那句"} =
               resolve_one(uri("proposal", proposal.id))
    end

    # A topic is a transcript. Surfacing any of it in a preview would put half a
    # conversation in front of a reader as though it were a conclusion.
    test "conversation gives up its title and nothing else" do
      conversation = insert(:conversation, title: "关于部署的讨论")
      insert(:message, conversation: conversation, content: "这条不该出现在预览里")

      resolved = resolve_one(uri("conversation", conversation.id))

      assert resolved.state == :ok
      assert resolved.title == "关于部署的讨论"
      assert resolved.excerpt == nil
      assert resolved.subtitle == nil
    end

    test "attachment gives up its filename" do
      attachment = insert(:attachment, filename: "topology.png", mime_type: "image/png")

      assert %{state: :ok, title: "topology.png", subtitle: "image/png"} =
               resolve_one(uri("attachment", attachment.id))
    end
  end

  describe "resolve/1 block liveness" do
    # Block rows are per-revision snapshots and the old ones stay forever, so
    # matching any revision would call a long-deleted block alive.
    test "a block dropped from the latest revision is broken" do
      {document, first} = document_with("上线流程")
      block = insert(:document_block, revision: first, content: "## 会被删掉的一节")

      second = insert_revision_after(first, document: document, title: "上线流程")
      insert(:document_block, revision: second, content: "## 留下来的一节")

      assert %{state: :broken} = resolve_one(uri("block", block.block_id))
    end

    test "a block carried into the latest revision keeps its identity" do
      {document, first} = document_with("上线流程")
      block = insert(:document_block, revision: first, content: "## 第一版")

      second = insert_revision_after(first, document: document, title: "上线流程")
      insert(:document_block, revision: second, block_id: block.block_id, content: "## 第二版")

      assert %{state: :ok, title: "第二版"} = resolve_one(uri("block", block.block_id))
    end
  end

  describe "resolve/1 archiving" do
    # Archiving is not deleting: the body is still there and so are its links.
    test "an archived document resolves, flagged" do
      {document, _revision} = document_with("旧方案", archived_at: DateTime.utc_now())

      assert %{state: :ok, archived: true} = resolve_one(uri("document", document.id))
    end

    test "a block in an archived document resolves, flagged" do
      {_document, revision} = document_with("旧方案", archived_at: DateTime.utc_now())
      block = insert(:document_block, revision: revision)

      assert %{state: :ok, archived: true} = resolve_one(uri("block", block.block_id))
    end

    test "an archived project is flagged" do
      project = insert(:project, status: :archived)

      assert %{state: :ok, archived: true} = resolve_one(uri("project", project.slug))
    end
  end

  describe "resolve/1 batching" do
    test "answers in the order asked" do
      task = insert(:task, title: "甲")
      conversation = insert(:conversation, title: "乙")

      uris = [uri("conversation", conversation.id), "rinto://intel/x", uri("task", task.id)]

      assert {:ok, [first, second, third]} = Resolver.resolve(uris)
      assert first.title == "乙"
      assert second.state == :unknown_type
      assert third.title == "甲"
    end

    # The caller lines results up against occurrences in a body, so collapsing
    # repeats would shift every result after the duplicate.
    test "repeats a URI that was asked for twice" do
      task = insert(:task, title: "甲")
      uri = uri("task", task.id)

      assert {:ok, [first, second]} = Resolver.resolve([uri, uri])
      assert first == second
      assert first.title == "甲"
    end

    test "answers an empty list" do
      assert {:ok, []} = Resolver.resolve([])
    end

    test "refuses a batch over the ceiling rather than truncating it" do
      max = Application.fetch_env!(:rinto_pmo, Resolver)[:max_references]
      uris = for _ <- 1..(max + 1), do: uri("task", UUIDv7.generate())

      assert {:error, :too_many_references, %{max: ^max}} = Resolver.resolve(uris)
    end
  end

  describe "resolve/1 excerpts" do
    test "truncates a long body" do
      max = Application.fetch_env!(:rinto_pmo, Resolver)[:max_excerpt_chars]
      task = insert(:task, description: String.duplicate("字", max * 2))

      excerpt = resolve_one(uri("task", task.id)).excerpt

      assert String.length(excerpt) == max + 1
      assert String.ends_with?(excerpt, "…")
    end

    test "leaves a blank body as nothing rather than an empty string" do
      task = insert(:task, description: nil)

      assert resolve_one(uri("task", task.id)).excerpt == nil
    end
  end

  # The loop the whole design turns on: whatever a search result hands out has
  # to parse back to the resource it named.
  describe "round trip with References" do
    test "every resolved URI parses back to the reference that produced it" do
      task = insert(:task)

      for uri <- [uri("task", task.id), uri("intel", "x")] do
        assert %{uri: ^uri} = resolve_one(uri)
        assert {:ok, reference} = References.parse(uri)
        assert References.to_uri(reference) == uri
      end
    end
  end
end
