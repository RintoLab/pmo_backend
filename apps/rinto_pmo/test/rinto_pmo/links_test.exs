defmodule RintoPMO.LinksTest do
  use RintoPMO.DataCase, async: true

  alias RintoPMO.Annotations
  alias RintoPMO.Conversations
  alias RintoPMO.Documents
  alias RintoPMO.Links.Link
  alias RintoPMO.Tasks

  defp uri(type, key), do: "rinto://#{type}/#{key}"

  defp links(source_type) do
    Link
    |> where([link], link.source_type == ^source_type)
    |> order_by([link], asc: link.source_id, asc: link.position)
    |> Repo.all()
  end

  defp targets_of(source_type), do: Enum.map(links(source_type), & &1.target_id)

  describe "documents" do
    test "creating a document indexes the references in its body" do
      task = insert(:task)
      actor = insert(:actor)

      {:ok, document} =
        Documents.create_document(%{
          title: "上线流程",
          actor_id: actor.id,
          project_id: insert(:project).id,
          markdown: "## 一\n\n先做 [接入](#{uri("task", task.id)})"
        })

      assert [link] = links("document_block")
      assert link.target_type == "task"
      assert link.target_id == task.id
      assert link.label == "接入"
      assert link.position == 0
      assert link.source_document_id == document.id
    end

    # `create_document/1` nests its first revision instead of going through
    # `insert_revision/4`, so it needs its own call into the index -- this is
    # the test that would have caught missing it.
    test "a document created with references does not wait for a later save" do
      task = insert(:task)
      actor = insert(:actor)

      {:ok, _document} =
        Documents.create_document(%{
          title: "甲",
          actor_id: actor.id,
          project_id: insert(:project).id,
          markdown: "见 [x](#{uri("task", task.id)})"
        })

      refute Enum.empty?(links("document_block"))
    end

    test "a revision that drops the reference empties the index" do
      task = insert(:task)
      actor = insert(:actor)

      {:ok, document} =
        Documents.create_document(%{
          title: "甲",
          actor_id: actor.id,
          project_id: insert(:project).id,
          markdown: "见 [x](#{uri("task", task.id)})"
        })

      assert [link] = links("document_block")

      {:ok, _revision} =
        Documents.create_revision(document, %{
          actor_id: actor.id,
          base_revision_id: document.latest_revision.id,
          block_ops: [
            %{op: "update", block_id: link.source_id, actor_id: actor.id, content: "现在什么都不引用了"}
          ]
        })

      assert links("document_block") == []
    end

    test "only the latest revision is indexed, so history is not noise" do
      first = insert(:task)
      second = insert(:task)
      actor = insert(:actor)

      {:ok, document} =
        Documents.create_document(%{
          title: "甲",
          actor_id: actor.id,
          project_id: insert(:project).id,
          markdown: "见 [x](#{uri("task", first.id)})"
        })

      assert [link] = links("document_block")

      {:ok, _revision} =
        Documents.create_revision(document, %{
          actor_id: actor.id,
          base_revision_id: document.latest_revision.id,
          block_ops: [
            %{
              op: "update",
              block_id: link.source_id,
              actor_id: actor.id,
              content: "改成 [y](#{uri("task", second.id)})"
            }
          ]
        })

      assert targets_of("document_block") == [second.id]
    end

    test "archiving a document leaves its references indexed" do
      task = insert(:task)
      actor = insert(:actor)

      {:ok, document} =
        Documents.create_document(%{
          title: "甲",
          actor_id: actor.id,
          project_id: insert(:project).id,
          markdown: "见 [x](#{uri("task", task.id)})"
        })

      {:ok, _archived} = Documents.archive_document(document)

      assert [_link] = links("document_block")
    end
  end

  describe "annotations" do
    test "creating, updating, and deleting follow the body" do
      document = insert(:document)
      insert(:document_revision, document: document)
      first = insert(:task)
      second = insert(:task)

      {:ok, annotation} =
        Annotations.create_annotation(document, %{
          actor_id: insert(:actor).id,
          content: "见 [x](#{uri("task", first.id)})"
        })

      assert [link] = links("annotation")
      assert link.target_id == first.id
      assert link.source_document_id == document.id

      {:ok, _updated} =
        Annotations.update_annotation(annotation, %{content: "改成 [y](#{uri("task", second.id)})"})

      assert targets_of("annotation") == [second.id]

      {:ok, _deleted} = Annotations.delete_annotation(annotation)
      assert links("annotation") == []
    end

    # The database cascades replies away when their annotation goes, and the
    # index does not see that happen. Their rows have to be read out while the
    # replies still exist, or every one of them is left pointing out of a thread
    # that no longer exists.
    test "deleting an annotation takes its replies' references with it" do
      document = insert(:document)
      insert(:document_revision, document: document)
      annotation = insert(:annotation, document: document)
      task = insert(:task)

      {:ok, _reply} =
        Annotations.create_reply(annotation, %{
          actor_id: insert(:actor).id,
          content: "见 [x](#{uri("task", task.id)})"
        })

      assert [_link] = links("annotation_reply")

      {:ok, _deleted} = Annotations.delete_annotation(annotation)

      assert links("annotation_reply") == []
    end

    test "replies are indexed and carry the document they were written in" do
      document = insert(:document)
      insert(:document_revision, document: document)
      annotation = insert(:annotation, document: document)
      task = insert(:task)

      {:ok, reply} =
        Annotations.create_reply(annotation, %{
          actor_id: insert(:actor).id,
          content: "同意，见 [x](#{uri("task", task.id)})"
        })

      assert [link] = links("annotation_reply")
      assert link.target_id == task.id
      assert link.source_document_id == document.id

      {:ok, _updated} = Annotations.update_reply(reply, %{content: "算了"})
      assert links("annotation_reply") == []

      {:ok, _second} =
        Annotations.create_reply(annotation, %{
          actor_id: insert(:actor).id,
          content: "又见 [x](#{uri("task", task.id)})"
        })

      assert [reply_link] = links("annotation_reply")
      assert reply_link.source_document_id == document.id
    end
  end

  describe "tasks" do
    test "a description's references are indexed, updated, and purged" do
      project = insert(:project)
      target = insert(:task)

      {:ok, task} =
        Tasks.create_task(project, %{
          title: "甲",
          description: "依赖 [那个](#{uri("task", target.id)})"
        })

      assert [link] = links("task")
      assert link.source_id == task.id
      assert link.target_id == target.id

      {:ok, _updated} = Tasks.update_task(task, %{description: "不依赖什么了"})
      assert links("task") == []

      {:ok, _again} =
        Tasks.update_task(task, %{description: "又依赖 [那个](#{uri("task", target.id)})"})

      assert [_one] = links("task")

      {:ok, _deleted} = Tasks.delete_task(task)
      assert links("task") == []
    end
  end

  describe "messages" do
    test "a URI written into the prose is indexed" do
      conversation = insert(:conversation)
      task = insert(:task)

      {:ok, _message} =
        Conversations.append_message(conversation, %{
          actor_id: insert(:actor).id,
          role: :user,
          content: "看看 [这个](#{uri("task", task.id)})"
        })

      assert [link] = links("message")
      assert link.target_id == task.id
    end

    # `reference#N` is the mention UI's own pointer into the `refs` array. It is
    # not a `rinto://` URI and has no business in this index.
    test "the mention pointers a client writes are not references" do
      conversation = insert(:conversation)

      {:ok, _message} =
        Conversations.append_message(conversation, %{
          actor_id: insert(:actor).id,
          role: :user,
          content: "看看 [这个](reference#0)"
        })

      assert links("message") == []
    end
  end

  describe "what stays and what goes" do
    # The reason there are no foreign keys: a dangling link that can be reported
    # as broken is the feature.
    test "deleting the target leaves the link standing" do
      project = insert(:project)
      target = insert(:task)

      {:ok, _task} =
        Tasks.create_task(project, %{
          title: "甲",
          description: "依赖 [那个](#{uri("task", target.id)})"
        })

      {:ok, _deleted} = Tasks.delete_task(target)

      assert [link] = links("task")
      assert link.target_id == target.id
      assert link.label == "那个"
    end

    test "one target cited twice is two rows, ordered" do
      project = insert(:project)
      target = insert(:task)

      {:ok, _task} =
        Tasks.create_task(project, %{
          title: "甲",
          description: "[头一次](#{uri("task", target.id)}) 和 [第二次](#{uri("task", target.id)})"
        })

      assert [first, second] = links("task")
      assert first.target_id == second.target_id
      assert [first.position, second.position] == [0, 1]
      assert [first.label, second.label] == ["头一次", "第二次"]
    end

    test "an unknown type is not indexed, though the body keeps it" do
      project = insert(:project)

      {:ok, task} =
        Tasks.create_task(project, %{
          title: "甲",
          description: "见 [情报](rinto://intel/whatever)"
        })

      assert links("task") == []
      assert task.description =~ "rinto://intel/whatever"
    end

    test "a reference inside a code block is content, not a link" do
      project = insert(:project)
      target = insert(:task)

      {:ok, _task} =
        Tasks.create_task(project, %{
          title: "甲",
          description: "```\n[x](#{uri("task", target.id)})\n```"
        })

      assert links("task") == []
    end
  end

  describe "how a target is keyed" do
    test "a project target is keyed by slug rather than id" do
      project = insert(:project, slug: "infra")

      {:ok, _task} =
        Tasks.create_task(insert(:project), %{
          title: "甲",
          description: "见 [基础设施](rinto://project/infra)"
        })

      assert [link] = links("task")
      assert link.target_type == "project"
      assert link.target_slug == "infra"
      assert link.target_id == nil
      assert project.slug == "infra"
    end
  end
end
