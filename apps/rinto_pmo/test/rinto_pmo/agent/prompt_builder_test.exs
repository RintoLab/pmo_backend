defmodule RintoPMO.Agent.PromptBuilderTest do
  use RintoPMO.DataCase, async: true

  alias RintoPMO.Agent.PromptBuilder
  alias RintoPMO.AnnotationsMock
  alias RintoPMO.AttachmentsMock
  alias RintoPMO.ConversationsMock
  alias RintoPMO.DocumentsMock
  alias RintoPMO.ProjectsMock

  describe "build/2 without refs" do
    test "passes the message through untouched" do
      assert {:ok, %{message: "hello", images: []}} = PromptBuilder.build("hello", [])
    end

    test "defaults to no refs" do
      assert {:ok, %{message: "hello"}} = PromptBuilder.build("hello")
    end
  end

  describe "build/2 with a document ref" do
    test "inlines the latest revision's blocks in position order" do
      document = document_with_blocks(["## Intro", "Body text"])

      expect(DocumentsMock, :get_document!, fn _id -> document end)

      assert {:ok, %{message: message}} =
               PromptBuilder.build("summarise it", [
                 %{"type" => "document", "id" => document.id}
               ])

      assert message =~ ~s(<document id="#{document.id}")
      assert message =~ ~s(blocks="2")
      assert [_before, intro, body] = String.split(message, "[block:")
      assert intro =~ "## Intro"
      assert body =~ "Body text"
    end

    test "keeps the user's message last so the question follows its context" do
      document = document_with_blocks(["Content"])

      expect(DocumentsMock, :get_document!, fn _id -> document end)

      assert {:ok, %{message: message}} =
               PromptBuilder.build("summarise it", [
                 %{"type" => "document", "id" => document.id}
               ])

      assert String.ends_with?(message, "\n\nsummarise it")
    end

    test "elides blocks past the budget and says so" do
      long = String.duplicate("x", 15_000)
      document = document_with_blocks([long, long, long])

      expect(DocumentsMock, :get_document!, fn _id -> document end)

      assert {:ok, %{message: message}} =
               PromptBuilder.build("read it", [%{"type" => "document", "id" => document.id}])

      assert message =~ ~s(truncated="true")
      assert message =~ "Remaining blocks omitted"
      assert message =~ ~s(blocks="3")
    end

    test "escapes a title that would otherwise break the element" do
      document = document_with_blocks(["Content"], ~s(A "quoted"\ntitle))

      expect(DocumentsMock, :get_document!, fn _id -> document end)

      assert {:ok, %{message: message}} =
               PromptBuilder.build("hi", [%{"type" => "document", "id" => document.id}])

      assert message =~ ~s(title="A &quot;quoted&quot; title")
    end
  end

  describe "build/2 with an annotation ref" do
    test "renders the thread with its replies" do
      document = insert(:document)

      annotation =
        insert(:annotation, document: document, content: "Needs a citation", block_text: "Claim")

      reply = insert(:annotation_reply, annotation: annotation, content: "Agreed", position: 0)
      annotation = %{annotation | replies: [reply]}

      expect(DocumentsMock, :get_document!, fn _id -> document end)
      expect(AnnotationsMock, :get_annotation!, fn ^document, _id -> annotation end)

      assert {:ok, %{message: message}} =
               PromptBuilder.build("resolve this", [
                 %{
                   "type" => "annotation",
                   "id" => annotation.id,
                   "document_id" => document.id
                 }
               ])

      assert message =~ ~s(<annotation id="#{annotation.id}")
      assert message =~ "block: Claim"
      assert message =~ "Needs a citation"
      assert message =~ ~s(<reply position="0">Agreed</reply>)
    end

    test "rejects an annotation ref with no document to scope it" do
      assert {:error, :invalid_ref, _details} =
               PromptBuilder.build("hi", [%{"type" => "annotation", "id" => UUIDv7.generate()}])
    end
  end

  describe "build/2 with a project ref" do
    test "indexes the project's documents so the agent can ask for one" do
      project = insert(:project, name: "Alpha", description: "The alpha project")
      document = document_with_blocks(["Content"], "Charter")

      expect(ProjectsMock, :get_project_by_slug!, fn slug ->
        assert slug == project.slug
        project
      end)

      expect(DocumentsMock, :list_documents, fn {:project, project_id} ->
        assert project_id == project.id
        [document]
      end)

      assert {:ok, %{message: message}} =
               PromptBuilder.build("what is this?", [
                 %{"type" => "project", "slug" => project.slug}
               ])

      assert message =~ ~s(<project slug="#{project.slug}" name="Alpha" status="active">)
      assert message =~ "The alpha project"
      assert message =~ "- #{document.id} Charter"
    end

    test "says so plainly when a project has no documents" do
      project = insert(:project)

      expect(ProjectsMock, :get_project_by_slug!, fn _slug -> project end)
      expect(DocumentsMock, :list_documents, fn _filter -> [] end)

      assert {:ok, %{message: message}} =
               PromptBuilder.build("hi", [%{"type" => "project", "slug" => project.slug}])

      assert message =~ "documents: none"
    end
  end

  describe "build/2 with an attachment ref" do
    test "puts the marker in the text and the bytes in images" do
      attachment = insert(:attachment, filename: "chart.png", width: 800, height: 600)
      image = %{"type" => "image", "mimeType" => "image/png", "data" => "QUJD"}

      expect(AttachmentsMock, :get_attachment!, fn _id -> attachment end)
      expect(AttachmentsMock, :image_content, fn ^attachment -> {:ok, image} end)
      expect(AttachmentsMock, :touch_attachments, fn ids -> assert_ids(ids, [attachment.id]) end)

      assert {:ok, %{message: message, images: [^image]}} =
               PromptBuilder.build("what does this show?", [
                 %{"type" => "attachment", "id" => attachment.id}
               ])

      assert message =~ ~s(<attachment id="#{attachment.id}" mime="image/png")
      assert message =~ ~s(width="800" height="600" filename="chart.png")
    end

    test "surfaces missing bytes rather than sending a marker with no image" do
      attachment = insert(:attachment)

      expect(AttachmentsMock, :get_attachment!, fn _id -> attachment end)

      expect(AttachmentsMock, :image_content, fn _attachment ->
        {:error, :attachment_unreadable, %{}}
      end)

      assert {:error, :attachment_unreadable, _details} =
               PromptBuilder.build("hi", [%{"type" => "attachment", "id" => attachment.id}])
    end
  end

  describe "build/2 with a conversation ref" do
    test "renders the recent turns so a cold topic can be picked back up" do
      conversation = insert(:conversation, title: "Tighten §3")
      actor = insert(:actor)

      messages = [
        insert(:message,
          conversation: conversation,
          actor: actor,
          role: :user,
          content: "Is §3 consistent with §1?",
          position: 0
        ),
        insert(:message,
          conversation: conversation,
          actor: actor,
          role: :assistant,
          content: "No -- §3 says the opposite.",
          position: 1
        )
      ]

      expect(ConversationsMock, :get_conversation!, fn id ->
        assert id == conversation.id
        conversation
      end)

      expect(ConversationsMock, :recent_messages, fn ^conversation, limit ->
        # The replay depth, not the whole topic.
        assert limit == 10
        messages
      end)

      assert {:ok, %{message: message}} =
               PromptBuilder.build("carry on", [
                 %{"type" => "conversation", "id" => conversation.id}
               ])

      assert message =~ ~s(<conversation id="#{conversation.id}" title="Tighten §3" turns="2">)
      assert message =~ ~s(<turn role="user" position="0">)
      assert message =~ "Is §3 consistent with §1?"
      assert message =~ ~s(<turn role="assistant" position="1">)
      assert message =~ "No -- §3 says the opposite."
      assert String.ends_with?(message, "\n\ncarry on")
    end

    test "names the conversation that no longer exists" do
      id = UUIDv7.generate()

      expect(ConversationsMock, :get_conversation!, fn _id ->
        raise Ecto.NoResultsError, queryable: RintoPMO.Conversations.Conversation
      end)

      assert {:error, :ref_not_found, %{"type" => "conversation", "id" => ^id}} =
               PromptBuilder.build("carry on", [%{"type" => "conversation", "id" => id}])
    end
  end

  describe "build/2 with several refs" do
    test "renders them in the order given, ahead of the message" do
      first = document_with_blocks(["One"], "First")
      second = document_with_blocks(["Two"], "Second")

      expect(DocumentsMock, :get_document!, 2, fn id ->
        if id == first.id, do: first, else: second
      end)

      assert {:ok, %{message: message}} =
               PromptBuilder.build("compare them", [
                 %{"type" => "document", "id" => first.id},
                 %{"type" => "document", "id" => second.id}
               ])

      [first_index, second_index] =
        Enum.map(["First", "Second"], fn title ->
          message |> String.split(title) |> hd() |> String.length()
        end)

      assert first_index < second_index
    end

    test "collects images from every attachment ref" do
      one = insert(:attachment)
      two = insert(:attachment)
      image = fn data -> %{"type" => "image", "mimeType" => "image/png", "data" => data} end

      expect(AttachmentsMock, :get_attachment!, 2, fn id ->
        if id == one.id, do: one, else: two
      end)

      expect(AttachmentsMock, :image_content, 2, fn attachment ->
        {:ok, image.(attachment.id)}
      end)

      # One stamp for the whole prompt, not one per image.
      expect(AttachmentsMock, :touch_attachments, fn ids -> assert_ids(ids, [one.id, two.id]) end)

      assert {:ok, %{images: images}} =
               PromptBuilder.build("both", [
                 %{"type" => "attachment", "id" => one.id},
                 %{"type" => "attachment", "id" => two.id}
               ])

      assert Enum.map(images, & &1["data"]) == [one.id, two.id]
    end
  end

  describe "build/2 failures" do
    test "names the reference that no longer exists" do
      id = UUIDv7.generate()

      expect(DocumentsMock, :get_document!, fn _id ->
        raise Ecto.NoResultsError, queryable: RintoPMO.Documents.Document
      end)

      assert {:error, :ref_not_found, %{"type" => "document", "id" => ^id}} =
               PromptBuilder.build("hi", [%{"type" => "document", "id" => id}])
    end

    test "stops at the first bad reference rather than sending a partial prompt" do
      good = document_with_blocks(["Content"])

      expect(DocumentsMock, :get_document!, fn _id -> good end)

      assert {:error, :invalid_ref, _details} =
               PromptBuilder.build("hi", [
                 %{"type" => "document", "id" => good.id},
                 %{"type" => "wormhole", "id" => "whatever"}
               ])
    end

    # An image that never reached a model was not used. Recording it as used
    # would teach a future retention sweep to keep exactly the wrong files.
    test "does not record a use when a later ref sinks the prompt" do
      attachment = insert(:attachment)
      image = %{"type" => "image", "mimeType" => "image/png", "data" => "QUJD"}

      expect(AttachmentsMock, :get_attachment!, fn _id -> attachment end)
      expect(AttachmentsMock, :image_content, fn _attachment -> {:ok, image} end)
      # No `touch_attachments` expectation: Hammox fails the test if it is called.

      assert {:error, :invalid_ref, _details} =
               PromptBuilder.build("hi", [
                 %{"type" => "attachment", "id" => attachment.id},
                 %{"type" => "wormhole"}
               ])
    end

    test "rejects a ref with no type" do
      assert {:error, :invalid_ref, _details} = PromptBuilder.build("hi", [%{"id" => "x"}])
    end

    test "rejects refs that are not a list" do
      assert {:error, :invalid_ref, _details} = PromptBuilder.build("hi", %{"type" => "document"})
    end
  end

  defp assert_ids(actual, expected) do
    assert Enum.sort(actual) == Enum.sort(expected)
    :ok
  end

  defp document_with_blocks(contents, title \\ "Doc") do
    document = insert(:document)
    revision = insert(:document_revision, document: document, title: title)

    blocks =
      contents
      |> Enum.with_index()
      |> Enum.map(fn {content, position} ->
        insert(:document_block, revision: revision, content: content, position: position)
      end)

    %{document | latest_revision: %{revision | blocks: blocks}}
  end
end
