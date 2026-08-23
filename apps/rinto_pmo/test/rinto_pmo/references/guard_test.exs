defmodule RintoPMO.References.GuardTest do
  use RintoPMO.DataCase, async: true

  alias RintoPMO.Annotations
  alias RintoPMO.Conversations
  alias RintoPMO.Documents
  alias RintoPMO.Tasks

  defp absent, do: "rinto://task/#{UUIDv7.generate()}"

  defp document_with(markdown) do
    {:ok, document} =
      Documents.create_document(%{
        title: "上线流程",
        actor_id: insert(:actor).id,
        project_id: insert(:project).id,
        markdown: markdown
      })

    document
  end

  describe "what is refused" do
    # Addresses are bare UUIDs that nobody types correctly from memory. A body
    # with a mistyped one saves without complaint and renders as a dead link
    # nobody notices until a reader follows it -- silent, which is the argument
    # for making it loud while somebody can still fix it.
    test "a body pointing at a task that does not exist" do
      uri = absent()

      assert {:error, :unresolvable_references, %{uris: [^uri]}} =
               Documents.create_document(%{
                 title: "甲",
                 actor_id: insert(:actor).id,
                 project_id: insert(:project).id,
                 markdown: "见 [没有的](#{uri})"
               })
    end

    test "every bad address at once, not the first one" do
      first = absent()
      second = absent()

      assert {:error, :unresolvable_references, %{uris: uris}} =
               Tasks.create_task(insert(:project), %{
                 title: "甲",
                 description: "见 [一](#{first}) 和 [二](#{second})"
               })

      assert Enum.sort(uris) == Enum.sort([first, second])
    end

    test "an annotation, a reply, and a task update" do
      document = document_with("## 一\n\n内容")
      actor = insert(:actor)

      assert {:error, :unresolvable_references, _} =
               Annotations.create_annotation(document, %{
                 actor_id: actor.id,
                 content: "见 [x](#{absent()})"
               })

      {:ok, annotation} =
        Annotations.create_annotation(document, %{actor_id: actor.id, content: "问题"})

      assert {:error, :unresolvable_references, _} =
               Annotations.create_reply(annotation, %{
                 actor_id: actor.id,
                 content: "见 [x](#{absent()})"
               })

      {:ok, task} = Tasks.create_task(insert(:project), %{title: "甲"})

      assert {:error, :unresolvable_references, _} =
               Tasks.update_task(task, %{description: "见 [x](#{absent()})"})
    end

    test "a revision, checked across every block it touches" do
      actor = insert(:actor)
      document = document_with("## 一\n\n甲")
      [block] = Repo.all(from b in RintoPMO.Documents.DocumentBlock, select: b)

      assert {:error, :unresolvable_references, _} =
               Documents.create_revision(document, %{
                 actor_id: actor.id,
                 base_revision_id: document.latest_revision.id,
                 block_ops: [
                   %{
                     op: "update",
                     block_id: block.block_id,
                     actor_id: actor.id,
                     content: "见 [x](#{absent()})"
                   }
                 ]
               })
    end

    test "nothing is written when a body is refused" do
      before = Repo.aggregate(RintoPMO.Documents.Document, :count)

      assert {:error, :unresolvable_references, _} =
               Documents.create_document(%{
                 title: "甲",
                 actor_id: insert(:actor).id,
                 project_id: insert(:project).id,
                 markdown: "见 [x](#{absent()})"
               })

      assert Repo.aggregate(RintoPMO.Documents.Document, :count) == before
    end
  end

  describe "what is allowed through" do
    test "an address that resolves" do
      task = insert(:task)

      assert {:ok, _document} =
               Documents.create_document(%{
                 title: "甲",
                 actor_id: insert(:actor).id,
                 project_id: insert(:project).id,
                 markdown: "见 [接入](rinto://task/#{task.id})"
               })
    end

    # A kind of thing this build has not learned yet still saves, still renders,
    # and simply is not indexed. Refusing it would make every future resource
    # type a breaking change for text already written.
    test "a type this build does not know" do
      assert {:ok, _task} =
               Tasks.create_task(insert(:project), %{
                 title: "甲",
                 description: "见 [情报](rinto://intel/whatever)"
               })
    end

    # Not a reference at all -- a link whose destination happens to start with
    # those characters. Refusing over one would make this a validator of link
    # syntax rather than of references.
    test "a malformed rinto URI" do
      assert {:ok, _task} =
               Tasks.create_task(insert(:project), %{
                 title: "甲",
                 description: "见 [坏的](rinto://task/not-a-uuid) 和 [更坏的](rinto://block:xyz)"
               })
    end

    test "an address inside a code block, which is content rather than a link" do
      assert {:ok, _task} =
               Tasks.create_task(insert(:project), %{
                 title: "甲",
                 description: "```\n[x](#{absent()})\n```"
               })
    end

    test "a project by slug" do
      insert(:project, slug: "infra")

      assert {:ok, _task} =
               Tasks.create_task(insert(:project), %{
                 title: "甲",
                 description: "归 [基础设施](rinto://project/infra) 管"
               })
    end

    # A conversation is a person or a model thinking out loud. Refusing to send
    # one over a mistyped link would trade the thing that matters for the index.
    test "a message, which is never refused" do
      assert {:ok, _message} =
               Conversations.append_message(insert(:conversation), %{
                 actor_id: insert(:actor).id,
                 role: :user,
                 content: "见 [没有的](#{absent()})"
               })
    end
  end

  describe "a deleted target" do
    # The address was good when it was written. Refusing the *next* edit of an
    # unrelated part of the body would make one deletion elsewhere hold a
    # document hostage.
    test "does not stop the body that already points at it from being edited" do
      task = insert(:task)
      uri = "rinto://task/#{task.id}"

      {:ok, edited} =
        Tasks.create_task(insert(:project), %{title: "甲", description: "见 [x](#{uri})"})

      {:ok, _deleted} = Tasks.delete_task(task)

      assert {:error, :unresolvable_references, %{uris: [^uri]}} =
               Tasks.update_task(edited, %{description: "见 [x](#{uri}) 还有新的一句"})
    end
  end
end
