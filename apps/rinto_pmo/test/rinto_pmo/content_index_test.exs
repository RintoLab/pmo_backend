defmodule RintoPMO.ContentIndexTest do
  use RintoPMO.DataCase, async: true

  alias RintoPMO.Annotations
  alias RintoPMO.Annotations.Annotation
  alias RintoPMO.Annotations.AnnotationReply
  alias RintoPMO.ContentIndex
  alias RintoPMO.Documents
  alias RintoPMO.Documents.BlockEmbedding
  alias RintoPMO.Projects.Project
  alias RintoPMO.Tasks
  alias RintoPMO.Tasks.Task

  defp blocks do
    BlockEmbedding
    |> order_by([projection], asc: projection.title)
    |> Repo.all()
  end

  # Stands in for the worker that will compute these.
  defp embed!(schema, id) do
    schema
    |> where([row], row.id == ^id)
    |> Repo.update_all(set: [embedding: Pgvector.new(List.duplicate(0.1, 1024))])

    Repo.get!(schema, id)
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

  describe "blocks are the one projected resource" do
    # A block is independently addressable, so it is independently findable: a
    # hit lands on the section that says the thing.
    test "each block is projected, and carries the way back up" do
      project = insert(:project)

      document =
        document_with(
          """
          ## 部署步骤

          先确认 systemd unit

          ## 回滚

          按上一版重放
          """,
          project: project
        )

      assert length(blocks()) == 2
      assert Enum.map(blocks(), & &1.title) == ["回滚", "部署步骤"]

      for block <- blocks() do
        assert block.document_id == document.id
        assert block.project_id == project.id
        assert is_nil(block.embedding)
      end

      assert Enum.any?(blocks(), &(&1.body =~ "systemd unit"))
    end

    test "a block with no heading falls back to its first line" do
      document_with("就是一段没有标题的话\n\n后面还有内容")

      assert [block] = blocks()
      assert block.title == "就是一段没有标题的话"
    end

    test "a block dropped by a new revision stops being findable" do
      actor = insert(:actor)
      document = document_with("## 会被删掉的一节\n\n内容")

      assert [block] = blocks()

      {:ok, _revision} =
        Documents.create_revision(document, %{
          actor_id: actor.id,
          base_revision_id: document.latest_revision.id,
          block_ops: [%{op: "delete", block_id: block.block_id, actor_id: actor.id}]
        })

      assert blocks() == []
    end
  end

  # `document_blocks` writes a new row for every block on every commit, so an
  # embedding column there would be null on all of them whenever one changed.
  # That is the entire reason blocks get a projection keyed by `block_id`, and
  # this is the test that says so.
  describe "a commit re-embeds only what it changed" do
    test "an untouched block keeps its vector across a revision" do
      actor = insert(:actor)
      document = document_with("## 改的那块\n\n原内容\n\n## 没改的那块\n\n别动我")

      for block <- blocks(), do: embed!(BlockEmbedding, block.id)
      assert Enum.all?(blocks(), & &1.embedding)

      edited = Enum.find(blocks(), &(&1.title == "改的那块"))

      {:ok, _revision} =
        Documents.create_revision(document, %{
          actor_id: actor.id,
          base_revision_id: document.latest_revision.id,
          block_ops: [
            %{
              op: "update",
              block_id: edited.block_id,
              actor_id: actor.id,
              content: "## 改的那块\n\n改过的内容"
            }
          ]
        })

      by_title = Map.new(blocks(), &{&1.title, &1})

      assert is_nil(by_title["改的那块"].embedding), "an edited block kept a stale vector"
      assert by_title["没改的那块"].embedding, "an untouched block was sent back for re-embedding"
    end

    test "rebuilding keeps every vector whose text is unchanged" do
      document_with("## 部署步骤\n\n先确认 systemd unit")
      for block <- blocks(), do: embed!(BlockEmbedding, block.id)

      ContentIndex.rebuild()

      assert blocks() != []

      assert Enum.all?(blocks(), & &1.embedding),
             "a rebuild sent unchanged blocks back for re-embedding"
    end
  end

  # Everything else keeps its vector on its own row, voided by the changeset
  # that rewrites the text it stood for.
  describe "resources that carry their own vector" do
    test "a task loses it on a text change and keeps it otherwise" do
      {:ok, task} = Tasks.create_task(insert(:project), %{title: "甲", description: "原来的说明"})
      embed!(Task, task.id)

      {:ok, task} = Tasks.update_task(task, %{due_on: ~D[2026-12-31]})
      assert Repo.get!(Task, task.id).embedding, "a due date change voided the vector"

      {:ok, task} = Tasks.update_task(task, %{description: "改过的说明"})
      refute Repo.get!(Task, task.id).embedding
    end

    test "a project loses it when its name changes" do
      project = insert(:project)
      embed!(Project, project.id)

      project
      |> Project.changeset(%{name: "改名了"})
      |> Repo.update!()

      refute Repo.get!(Project, project.id).embedding
    end

    # Embedded separately rather than as one thread: a reply arriving must not
    # re-embed everything above it, or a long thread re-embeds itself over and
    # over across text that keeps growing.
    test "an annotation and its replies each carry their own" do
      document = document_with("## 一\n\n内容")
      actor = insert(:actor)

      {:ok, annotation} =
        Annotations.create_annotation(document, %{actor_id: actor.id, content: "问题"})

      {:ok, reply} = Annotations.create_reply(annotation, %{actor_id: actor.id, content: "回答"})

      embed!(Annotation, annotation.id)
      embed!(AnnotationReply, reply.id)

      {:ok, _second} =
        Annotations.create_reply(annotation, %{actor_id: actor.id, content: "再补一句"})

      assert Repo.get!(Annotation, annotation.id).embedding,
             "a new reply re-embedded the whole thread"

      {:ok, _updated} = Annotations.update_reply(reply, %{content: "改过的回答"})

      refute Repo.get!(AnnotationReply, reply.id).embedding
      assert Repo.get!(Annotation, annotation.id).embedding
    end
  end
end
