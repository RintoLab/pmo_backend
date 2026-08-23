defmodule RintoPMO.ContentIndexTest do
  use RintoPMO.DataCase, async: true

  alias RintoPMO.Annotations
  alias RintoPMO.ContentIndex
  alias RintoPMO.Conversations
  alias RintoPMO.Documents
  alias RintoPMO.Search.Searchable
  alias RintoPMO.Tasks

  defp projections(resource_type) do
    Searchable
    |> where([searchable], searchable.resource_type == ^resource_type)
    |> order_by([searchable], asc: searchable.title)
    |> Repo.all()
  end

  defp document_with(markdown, opts \\ []) do
    actor = insert(:actor)
    project = Keyword.get_lazy(opts, :project, fn -> insert(:project) end)

    {:ok, document} =
      Documents.create_document(%{
        title: Keyword.get(opts, :title, "上线流程"),
        actor_id: actor.id,
        project_id: project.id,
        markdown: markdown
      })

    document
  end

  describe "documents and blocks" do
    # A block is independently addressable, so it is independently findable: a
    # hit should land on the section that says the thing.
    test "each block is projected on its own, alongside the document" do
      project = insert(:project)

      document =
        document_with(
          """
          ## 部署步骤

          先确认 systemd unit

          ## 回滚

          按上一版重放
          """,
          project: project,
          title: "上线流程"
        )

      assert [document_row] = projections("document")
      assert document_row.resource_id == document.id
      assert document_row.title == "上线流程"
      assert document_row.body == nil
      assert document_row.project_id == project.id

      blocks = projections("block")
      assert length(blocks) == 2

      titles = Enum.map(blocks, & &1.title)
      assert "部署步骤" in titles
      assert "回滚" in titles

      for block <- blocks do
        assert block.document_id == document.id
        assert block.project_id == project.id
      end

      assert Enum.any?(blocks, &(&1.body =~ "systemd unit"))
    end

    test "a block with no heading falls back to its first line" do
      document_with("就是一段没有标题的话\n\n后面还有内容")

      assert [block] = projections("block")
      assert block.title == "就是一段没有标题的话"
    end

    # A revision can drop a block entirely, and a per-block rewrite would leave
    # the dropped one findable.
    test "a block dropped by a new revision stops being findable" do
      actor = insert(:actor)
      document = document_with("## 会被删掉的一节\n\n内容")

      assert [block] = projections("block")

      {:ok, _revision} =
        Documents.create_revision(document, %{
          actor_id: actor.id,
          base_revision_id: document.latest_revision.id,
          block_ops: [%{op: "delete", block_id: block.resource_id, actor_id: actor.id}]
        })

      assert projections("block") == []
      assert [_document] = projections("document")
    end

    test "archiving flags the document and its blocks without removing them" do
      document = document_with("## 一\n\n内容")

      {:ok, _archived} = Documents.archive_document(document)

      # Archiving does not itself re-index; the flag lands on the next write.
      {:ok, _revision} =
        Documents.create_revision(document, %{
          actor_id: insert(:actor).id,
          base_revision_id: document.latest_revision.id,
          block_ops: []
        })

      assert [row] = projections("document")
      assert row.archived
      assert Enum.all?(projections("block"), & &1.archived)
    end
  end

  describe "tasks" do
    test "title and description are projected, and follow edits" do
      project = insert(:project)

      {:ok, task} =
        Tasks.create_task(project, %{title: "接入 r-nacos", description: "先确认 systemd unit"})

      assert [row] = projections("task")
      assert row.title == "接入 r-nacos"
      assert row.body == "先确认 systemd unit"
      assert row.project_id == project.id

      {:ok, _updated} = Tasks.update_task(task, %{title: "改名了"})
      assert [%{title: "改名了"}] = projections("task")

      {:ok, _deleted} = Tasks.delete_task(task)
      assert projections("task") == []
    end

    test "re-projecting replaces rather than accumulating" do
      {:ok, task} = Tasks.create_task(insert(:project), %{title: "甲"})

      for name <- ~w(乙 丙 丁), do: Tasks.update_task(task, %{title: name})

      assert [%{title: "丁"}] = projections("task")
    end
  end

  describe "annotations" do
    # A thread is one thing to look for. Returning the annotation and four of
    # its replies as five hits would report the same conversation five times.
    test "replies fold into their annotation rather than getting rows" do
      document = document_with("## 一\n\n内容")
      actor = insert(:actor)

      {:ok, annotation} =
        Annotations.create_annotation(document, %{actor_id: actor.id, content: "这里要补一句"})

      {:ok, _first} =
        Annotations.create_reply(annotation, %{actor_id: actor.id, content: "同意，补哪一句"})

      {:ok, _second} =
        Annotations.create_reply(annotation, %{actor_id: actor.id, content: "补 systemd 那句"})

      assert [row] = projections("annotation")
      assert row.body =~ "这里要补一句"
      assert row.body =~ "同意，补哪一句"
      assert row.body =~ "补 systemd 那句"
      assert row.document_id == document.id
      assert projections("annotation_reply") == []
    end

    test "deleting a reply takes it back out of the thread's text" do
      document = document_with("## 一\n\n内容")
      actor = insert(:actor)

      {:ok, annotation} =
        Annotations.create_annotation(document, %{actor_id: actor.id, content: "问题"})

      {:ok, reply} =
        Annotations.create_reply(annotation, %{actor_id: actor.id, content: "会消失的回复"})

      assert [row] = projections("annotation")
      assert row.body =~ "会消失的回复"

      {:ok, _deleted} = Annotations.delete_reply(reply)

      assert [row] = projections("annotation")
      refute row.body =~ "会消失的回复"
    end

    test "deleting the annotation takes the whole thread out" do
      document = document_with("## 一\n\n内容")
      actor = insert(:actor)

      {:ok, annotation} =
        Annotations.create_annotation(document, %{actor_id: actor.id, content: "问题"})

      {:ok, _reply} = Annotations.create_reply(annotation, %{actor_id: actor.id, content: "回复"})
      {:ok, _deleted} = Annotations.delete_annotation(annotation)

      assert projections("annotation") == []
    end
  end

  describe "what is deliberately not projected" do
    # A topic is a transcript. Returning half of one as a hit reads as a
    # conclusion -- the same reason a conversation is linkable but never
    # expandable.
    test "a message is not findable" do
      {:ok, _message} =
        Conversations.append_message(insert(:conversation), %{
          actor_id: insert(:actor).id,
          role: :user,
          content: "这句话不该被搜到"
        })

      assert projections("message") == []
    end

    test "a task with no description is still findable by its title alone" do
      {:ok, _task} = Tasks.create_task(insert(:project), %{title: "甲"})

      assert [row] = projections("task")
      assert row.title == "甲"
      assert row.body == nil
    end
  end

  # `embedding IS NULL` is the entire "does this need embedding" state, so what
  # clears it decides how often the embedding service gets called. Blindly
  # clearing on every rewrite would turn a rebuild into a full re-embedding of
  # the corpus.
  describe "when a rewrite clears the embedding" do
    defp embed!(row) do
      vector = Pgvector.new(List.duplicate(0.1, 1024))

      Searchable
      |> where([searchable], searchable.id == ^row.id)
      |> Repo.update_all(set: [embedding: vector])

      Repo.get!(Searchable, row.id)
    end

    test "changed text clears it" do
      {:ok, task} = Tasks.create_task(insert(:project), %{title: "甲", description: "原来的说明"})
      [row] = projections("task")
      assert embed!(row).embedding

      {:ok, _updated} = Tasks.update_task(task, %{description: "改过的说明"})

      assert [%{embedding: nil}] = projections("task")
    end

    test "a changed title clears it too" do
      {:ok, task} = Tasks.create_task(insert(:project), %{title: "甲"})
      [row] = projections("task")
      assert embed!(row).embedding

      {:ok, _updated} = Tasks.update_task(task, %{title: "乙"})

      assert [%{embedding: nil}] = projections("task")
    end

    test "a change to something that is not embedded keeps it" do
      project = insert(:project)
      {:ok, task} = Tasks.create_task(project, %{title: "甲", description: "说明"})
      [row] = projections("task")
      assert embed!(row).embedding

      {:ok, _updated} = Tasks.update_task(task, %{due_on: ~D[2026-12-31]})

      assert [%{embedding: kept}] = projections("task")
      assert kept
    end

    # The case that actually costs money: a repair must not re-embed everything
    # it touched.
    test "rebuilding keeps every vector whose text is unchanged" do
      document_with("## 部署步骤\n\n先确认 systemd unit")
      {:ok, _task} = Tasks.create_task(insert(:project), %{title: "甲", description: "乙"})

      for row <- Repo.all(Searchable), do: embed!(row)
      assert Enum.all?(Repo.all(Searchable), & &1.embedding)

      ContentIndex.rebuild()

      assert Repo.all(Searchable) != []

      assert Enum.all?(Repo.all(Searchable), & &1.embedding),
             "a rebuild sent unchanged rows back for re-embedding"
    end
  end

  describe "rebuild covers both indexes" do
    test "restores projections that were dropped" do
      document_with("## 部署步骤\n\n先确认 systemd unit")
      {:ok, _task} = Tasks.create_task(insert(:project), %{title: "甲", description: "乙"})

      before = %{
        documents: length(projections("document")),
        blocks: length(projections("block")),
        tasks: length(projections("task"))
      }

      Repo.delete_all(Searchable)
      assert projections("block") == []

      ContentIndex.rebuild()

      assert %{
               documents: length(projections("document")),
               blocks: length(projections("block")),
               tasks: length(projections("task"))
             } == before
    end
  end
end
