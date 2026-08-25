defmodule RintoPMO.LinksBacklinksTest do
  use RintoPMO.DataCase, async: true

  alias RintoPMO.Annotations
  alias RintoPMO.Conversations
  alias RintoPMO.Documents
  alias RintoPMO.Links
  alias RintoPMO.References
  alias RintoPMO.Tasks

  defp uri(type, key), do: "rinto://#{type}/#{key}"

  defp backlinks(uri) do
    assert {:ok, reference} = References.parse(uri)
    Links.backlinks(reference)
  end

  defp document_citing(markdown) do
    actor = insert(:actor)

    {:ok, document} =
      Documents.create_document(%{
        title: "上线流程",
        actor_id: actor.id,
        project_id: insert(:project).id,
        markdown: markdown
      })

    document
  end

  test "a block that cites a task is found from the task" do
    task = insert(:task)
    document = document_citing("## 一\n\n先做 [接入](#{uri("task", task.id)})")

    assert [entry] = backlinks(uri("task", task.id))
    assert entry.source_type == "document_block"
    assert entry.document_id == document.id
    assert entry.document_title == "上线流程"
    assert entry.label == "接入"
    assert entry.excerpt =~ "接入"
    refute entry.archived
  end

  test "every kind of source is found, and each says where it lives" do
    task = insert(:task)
    target = uri("task", task.id)
    actor = insert(:actor)

    document = document_citing("见 [甲](#{target})")

    {:ok, annotation} =
      Annotations.create_annotation(document, %{actor_id: actor.id, content: "见 [乙](#{target})"})

    {:ok, _reply} =
      Annotations.create_reply(annotation, %{actor_id: actor.id, content: "见 [丙](#{target})"})

    {:ok, _task} =
      Tasks.create_task(insert(:project), %{title: "甲", description: "见 [丁](#{target})"})

    conversation = insert(:conversation, title: "关于部署")

    {:ok, _message} =
      Conversations.append_message(conversation, %{
        actor_id: actor.id,
        role: :user,
        content: "见 [戊](#{target})"
      })

    found = backlinks(target)

    assert length(found) == 5

    assert MapSet.new(found, & &1.source_type) ==
             MapSet.new(~w(document_block annotation annotation_reply task message))

    by_type = Map.new(found, &{&1.source_type, &1})

    assert by_type["annotation"].document_id == document.id
    assert by_type["annotation_reply"].document_title == "上线流程"
    assert by_type["task"].title == "甲"
    assert by_type["message"].title == "关于部署"
  end

  # The transcript stays out of it, the same way a conversation is linkable but
  # never expandable.
  test "a message contributes its topic's title, not its text" do
    task = insert(:task)
    conversation = insert(:conversation, title: "关于部署")

    {:ok, _message} =
      Conversations.append_message(conversation, %{
        actor_id: insert(:actor).id,
        role: :user,
        content: "这句不该出现在反查里，见 [x](#{uri("task", task.id)})"
      })

    assert [entry] = backlinks(uri("task", task.id))
    assert entry.title == "关于部署"
    assert entry.excerpt == nil
  end

  test "a project is found by slug" do
    insert(:project, slug: "infra")
    document_citing("归 [基础设施](rinto://project/infra) 管")

    assert [entry] = backlinks("rinto://project/infra")
    assert entry.label == "基础设施"
  end

  # The row outlives its target. That is the whole reason there are no foreign
  # keys, so the query has to keep working after the target is gone.
  test "a reference to a deleted target is still reported" do
    task = insert(:task)
    document_citing("见 [没了的](#{uri("task", task.id)})")

    {:ok, _deleted} = Tasks.delete_task(task)

    assert [entry] = backlinks(uri("task", task.id))
    assert entry.label == "没了的"
  end

  test "a source that was deleted is gone from the answer" do
    target = insert(:task)

    {:ok, task} =
      Tasks.create_task(insert(:project), %{
        title: "甲",
        description: "见 [x](#{uri("task", target.id)})"
      })

    assert [_entry] = backlinks(uri("task", target.id))

    {:ok, _deleted} = Tasks.delete_task(task)

    assert backlinks(uri("task", target.id)) == []
  end

  test "citing one target twice answers twice, distinguishably" do
    task = insert(:task)
    target = uri("task", task.id)

    {:ok, _task} =
      Tasks.create_task(insert(:project), %{
        title: "甲",
        description: "[头一次](#{target}) 和 [第二次](#{target})"
      })

    assert [first, second] = Enum.sort_by(backlinks(target), & &1.position)
    assert [first.label, second.label] == ["头一次", "第二次"]
  end

  test "a source in an archived document is flagged rather than hidden" do
    task = insert(:task)
    document = document_citing("见 [x](#{uri("task", task.id)})")

    {:ok, _archived} = Documents.archive_document(document)

    assert [entry] = backlinks(uri("task", task.id))
    assert entry.archived
  end

  test "nothing pointing at it is an empty answer, not an error" do
    assert backlinks(uri("task", UUIDv7.generate())) == []
    assert backlinks("rinto://intel/whatever") == []
  end

  test "a block target is found through the block's own URI" do
    document = insert(:document)
    revision = insert(:document_revision, document: document)
    block = insert(:document_block, revision: revision)

    {:ok, _task} =
      Tasks.create_task(insert(:project), %{
        title: "甲",
        description: "见 [那一块](#{uri("block", block.block_id)})"
      })

    assert [entry] = backlinks(uri("block", block.block_id))
    assert entry.source_type == "task"
    assert entry.label == "那一块"
  end
end
