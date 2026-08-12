defmodule RintoPMO.Agent.PromptBuilderTest do
  use RintoPMO.DataCase, async: true

  alias RintoPMO.Agent.PromptBuilder
  alias RintoPMO.AnnotationsMock
  alias RintoPMO.AttachmentsMock
  alias RintoPMO.ConversationsMock
  alias RintoPMO.DocumentsMock
  alias RintoPMO.ProjectsMock

  setup do
    # Replay hands a revived session its own standing proposals; a topic with
    # none is the ordinary case, so tests about anything else say nothing.
    stub(DocumentsMock, :live_conversation_proposals, fn _conversation_id -> [] end)
    :ok
  end

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

      assert message =~ ~s(<document ref="1" id="#{document.id}")
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

      assert message =~ ~s(<annotation ref="1" id="#{annotation.id}")
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

      assert message =~ ~s(<project ref="1" slug="#{project.slug}" name="Alpha" status="active">)
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

      assert message =~ ~s(<attachment ref="1" id="#{attachment.id}" mime="image/png")
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

  describe "build/3 with a proposal ref" do
    test "renders the proposed text and names its topic without expanding it" do
      conversation = insert(:conversation, title: "Tighten §3")
      document = document_with_blocks(["Original"])

      proposal =
        insert(:block_proposal,
          document: document,
          conversation: conversation,
          content: "Rewritten paragraph.",
          status: :live
        )

      expect(DocumentsMock, :get_document!, fn _id -> document end)

      expect(DocumentsMock, :get_proposal!, fn ^document, id ->
        assert id == proposal.id
        proposal
      end)

      expect(ConversationsMock, :get_conversation!, fn _id -> conversation end)

      assert {:ok, %{message: message}} =
               PromptBuilder.build("which reads better?", [
                 %{"type" => "proposal", "id" => proposal.id, "document_id" => document.id}
               ])

      assert message =~ ~s(<proposal ref="1" id="#{proposal.id}")
      assert message =~ ~s(block_id="#{proposal.block_id}")
      assert message =~ ~s(status="live")
      # The topic is a label. Expanding it would be a conversation reference by
      # another name, and the whole point is that this expansion terminates.
      assert message =~ ~s(conversation="Tighten §3")
      assert message =~ "Rewritten paragraph."
      refute message =~ "<turn"
      refute message =~ "Original"
    end

    test "renders a rejected proposal, which is useful context in an adjudication" do
      document = document_with_blocks(["Original"])
      proposal = insert(:block_proposal, document: document, status: :rejected)

      expect(DocumentsMock, :get_document!, fn _id -> document end)
      expect(DocumentsMock, :get_proposal!, fn _document, _id -> proposal end)
      expect(ConversationsMock, :get_conversation!, fn _id -> proposal.conversation end)

      assert {:ok, %{message: message}} =
               PromptBuilder.build("why was this dropped?", [
                 %{"type" => "proposal", "id" => proposal.id, "document_id" => document.id}
               ])

      assert message =~ ~s(status="rejected")
    end

    test "refuses a proposal ref with no document to scope it" do
      assert {:error, :invalid_ref, _details} =
               PromptBuilder.build("hi", [%{"type" => "proposal", "id" => UUIDv7.generate()}])
    end
  end

  describe "build/3 replay" do
    test "hands back the tail with each turn naming what it referenced" do
      conversation = insert(:conversation, title: "Tighten §3")
      document = document_with_blocks(["The current text"])

      messages = [
        replayed_message(conversation, :user, 0, "tighten this", [
          message_ref_for(document)
        ]),
        replayed_message(conversation, :assistant, 1, "how about this?", [])
      ]

      expect(ConversationsMock, :recent_messages, fn ^conversation, limit ->
        # A safety valve set high enough not to be reached, not a budget.
        assert limit == 200
        messages
      end)

      # Re-expanded against the document as it stands now, not as it was.
      expect(DocumentsMock, :get_document!, fn _id -> document end)

      assert {:ok, %{message: message}} =
               PromptBuilder.build("carry on", [], replay: conversation)

      assert message =~ ~s(<conversation id="#{conversation.id}" title="Tighten §3" turns="2">)
      assert message =~ ~s(<turn role="user" position="0" refs="document:#{document.id}">)
      assert message =~ "tighten this"
      assert message =~ ~s(<turn role="assistant" position="1">)
      assert message =~ "<document ref=\"1\" id=\"#{document.id}\""
      assert message =~ "The current text"
      assert String.ends_with?(message, "\n\ncarry on")
    end

    test "expands a document once when replay and the prompt both cite it" do
      conversation = insert(:conversation)
      document = document_with_blocks(["The current text"])

      expect(ConversationsMock, :recent_messages, fn _conversation, _limit ->
        [replayed_message(conversation, :user, 0, "tighten this", [message_ref_for(document)])]
      end)

      # One lookup, one expansion, however many times it was cited.
      expect(DocumentsMock, :get_document!, fn _id -> document end)

      assert {:ok, %{message: message}} =
               PromptBuilder.build(
                 "and again",
                 [%{"type" => "document", "id" => document.id}],
                 replay: conversation
               )

      assert length(String.split(message, "<document ref=")) == 2
    end

    test "does not follow a conversation reference inside the replayed turns" do
      conversation = insert(:conversation)
      other = insert(:conversation)

      nested = %{"type" => "conversation", "id" => other.id}

      expect(ConversationsMock, :recent_messages, fn _conversation, _limit ->
        [
          replayed_message(conversation, :user, 0, "compare with the other topic", [
            build(:message_ref,
              message: nil,
              ref_type: "conversation",
              ref_id: other.id,
              payload: nested
            )
          ])
        ]
      end)

      # No `get_conversation!` expectation: reaching for the nested topic would
      # fail the test, which is the point -- one level only.
      assert {:ok, %{message: message}} =
               PromptBuilder.build("carry on", [], replay: conversation)

      assert message =~ "compare with the other topic"
      # The nested topic is not even named on the turn.
      refute message =~ other.id
    end

    test "passes the message through when the topic has no turns yet" do
      conversation = insert(:conversation)

      expect(ConversationsMock, :recent_messages, fn _conversation, _limit -> [] end)

      assert {:ok, %{message: message}} =
               PromptBuilder.build("first thing", [], replay: conversation)

      assert message =~ ~s(turns="0")
      assert String.ends_with?(message, "\n\nfirst thing")
    end
  end

  describe "build/3 mentions" do
    test "rewrites an index href to the id, and names the placeholder label" do
      document = document_with_blocks(["The current text"], "上线流程")

      expect(DocumentsMock, :get_document!, fn _id -> document end)

      assert {:ok, %{message: message}} =
               PromptBuilder.build(
                 "看看 [document](reference#0)",
                 [%{"type" => "document", "id" => document.id}]
               )

      # The element carries the same handle the mention points at.
      assert message =~ ~s(<document ref="1")
      assert message =~ "看看 [上线流程](ref#1)"
      refute message =~ "reference#0"
    end

    # The case the client cannot avoid: its mention UI has no way to reuse an
    # entry already in the array, so discussing two documents in four mentions
    # sends four refs -- and the backend collapses them to two expansions.
    test "points repeated mentions of one document at the same expansion" do
      first = document_with_blocks(["A says stage it"], "上线流程")
      second = document_with_blocks(["B says ship it"], "发布规范")

      stub(DocumentsMock, :get_document!, fn id ->
        if id == first.id, do: first, else: second
      end)

      refs = [
        %{"type" => "document", "id" => first.id},
        %{"type" => "document", "id" => second.id},
        %{"type" => "document", "id" => first.id},
        %{"type" => "document", "id" => second.id}
      ]

      body =
        "这个 [document](reference#0) 是这么说的，但 [document](reference#1) 是这么说的，" <>
          "所以哪个对？[document](reference#2) or [document](reference#3)?"

      assert {:ok, %{message: message}} = PromptBuilder.build(body, refs)

      # Four mentions, two distinct handles, and every one of them resolvable.
      refute message =~ "reference#"
      assert length(String.split(message, "(ref#1)")) == 3
      assert length(String.split(message, "(ref#2)")) == 3

      # Still expanded once each, which is what made the indices unusable.
      assert length(String.split(message, "<document ref=")) == 3
    end

    test "uses the slug for a project, matching what the element renders" do
      project = insert(:project, slug: "kenton", name: "Kenton")

      expect(ProjectsMock, :get_project_by_slug!, fn _slug -> project end)
      expect(DocumentsMock, :list_documents, fn _filter -> [] end)

      assert {:ok, %{message: message}} =
               PromptBuilder.build("[project](reference#0)这是啥", [
                 %{"type" => "project", "slug" => "kenton"}
               ])

      assert message =~ ~s(<project ref="1" slug="kenton")
      assert message =~ "[Kenton](ref#1)这是啥"
    end

    test "leaves a label the client wrote itself" do
      document = document_with_blocks(["Text"], "上线流程")

      expect(DocumentsMock, :get_document!, fn _id -> document end)

      assert {:ok, %{message: message}} =
               PromptBuilder.build(
                 "看看 [我自己起的名字](reference#0)",
                 [%{"type" => "document", "id" => document.id}]
               )

      assert message =~ "[我自己起的名字](ref#1)"
    end

    # Nothing here knows what was meant, so a pointer that visibly goes nowhere
    # beats one invented to look right.
    test "leaves an index with no ref behind it exactly as it stands" do
      document = document_with_blocks(["Text"])

      expect(DocumentsMock, :get_document!, fn _id -> document end)

      assert {:ok, %{message: message}} =
               PromptBuilder.build("[document](reference#7) and [document](reference#0)", [
                 %{"type" => "document", "id" => document.id}
               ])

      assert message =~ "[document](reference#7)"
      assert message =~ "(ref#1)"
    end

    test "keeps an annotation reading as its type word, having no title to offer" do
      document = document_with_blocks(["Block text"])
      annotation = insert(:annotation, document: document, content: "This is wrong")

      expect(DocumentsMock, :get_document!, fn _id -> document end)
      expect(AnnotationsMock, :get_annotation!, fn _document, _id -> annotation end)

      assert {:ok, %{message: message}} =
               PromptBuilder.build("[annotation](reference#0) 说什么", [
                 %{
                   "type" => "annotation",
                   "id" => annotation.id,
                   "document_id" => document.id
                 }
               ])

      assert message =~ "[annotation](ref#1) 说什么"
    end

    # A turn's hrefs index the array *that turn* sent, so the mapping is per
    # message. `position` is what makes it reproducible weeks later.
    test "rewrites a replayed turn against the positions it was stored with" do
      conversation = insert(:conversation)
      document = document_with_blocks(["The current text"], "上线流程")

      stored =
        build(:message_ref,
          message: nil,
          position: 3,
          ref_type: "document",
          ref_id: document.id,
          payload: %{"type" => "document", "id" => document.id}
        )

      expect(ConversationsMock, :recent_messages, fn _conversation, _limit ->
        [replayed_message(conversation, :user, 0, "改一下 [document](reference#3)", [stored])]
      end)

      expect(DocumentsMock, :get_document!, fn _id -> document end)

      assert {:ok, %{message: message}} =
               PromptBuilder.build("继续", [], replay: conversation)

      assert message =~ "改一下 [上线流程](ref#1)"
      refute message =~ "reference#3"
    end

    # A skipped reference is still an expansion and still holds a handle, so the
    # mention that cited it lands on "the thing you cited is gone" rather than
    # on nothing at all.
    test "points a mention at the marker left for a reference that has gone" do
      gone = UUIDv7.generate()

      expect(DocumentsMock, :get_document!, fn _id ->
        raise Ecto.NoResultsError, queryable: RintoPMO.Documents.Document
      end)

      assert {:ok, %{message: message}} =
               PromptBuilder.build(
                 "看看 [document](reference#0)",
                 [%{"type" => "document", "id" => gone}],
                 on_missing_refs: :skip
               )

      assert message =~ ~s(<reference ref="1" status="unavailable")
      assert message =~ "看看 [document](ref#1)"
    end

    test "does not touch a body with no refs to resolve against" do
      assert {:ok, %{message: "[document](reference#0) 呢"}} =
               PromptBuilder.build("[document](reference#0) 呢", [])
    end
  end

  # A proposal is a row, not a message reference, so replay would otherwise lose
  # it: a revived session would see the document as it now stands and none of its
  # own work against it, and would rewrite from the base -- discarding what it had
  # already put up for review.
  describe "build/3 replay of a topic's own proposals" do
    test "hands back the whole-document rewrite it had standing" do
      conversation = insert(:conversation)
      document = document_with_blocks(["The current text"])

      proposal =
        insert(:block_proposal,
          document: document,
          conversation: conversation,
          scope: :document,
          block_id: nil,
          content: "## Rewritten\n\nMy version"
        )

      expect(ConversationsMock, :recent_messages, fn _conversation, _limit -> [] end)
      expect(DocumentsMock, :live_conversation_proposals, fn _id -> [proposal] end)
      # Fetched through the ordinary proposal ref path, so it needs its document,
      # and names the topic that made it -- which for a topic's own proposal is
      # the topic itself.
      expect(DocumentsMock, :get_document!, fn _id -> document end)
      expect(DocumentsMock, :get_proposal!, fn ^document, _id -> proposal end)
      stub(ConversationsMock, :get_conversation!, fn _id -> conversation end)

      assert {:ok, %{message: message}} =
               PromptBuilder.build("carry on", [], replay: conversation)

      assert message =~ ~s(<proposal ref="1" id="#{proposal.id}" scope="document" status="live")
      assert message =~ "## Rewritten"
      # No block to name on a whole-document rewrite, so the attribute is absent
      # rather than empty.
      refute message =~ ~s(block_id="")
    end

    test "puts what it proposed after the document it proposed it for" do
      conversation = insert(:conversation)
      document = document_with_blocks(["The current text"], "上线流程")

      proposal =
        insert(:block_proposal,
          document: document,
          conversation: conversation,
          content: "Tighter"
        )

      message_ref =
        build(:message_ref,
          message: nil,
          ref_type: "document",
          ref_id: document.id,
          payload: %{"type" => "document", "id" => document.id}
        )

      expect(ConversationsMock, :recent_messages, fn _conversation, _limit ->
        [replayed_message(conversation, :user, 0, "tighten this", [message_ref])]
      end)

      expect(DocumentsMock, :live_conversation_proposals, fn _id -> [proposal] end)
      stub(DocumentsMock, :get_document!, fn _id -> document end)
      expect(DocumentsMock, :get_proposal!, fn ^document, _id -> proposal end)
      stub(ConversationsMock, :get_conversation!, fn _id -> conversation end)

      assert {:ok, %{message: message}} =
               PromptBuilder.build("carry on", [], replay: conversation)

      # Reads as: here is the document, here is what you proposed for it, here is
      # what you said.
      document_at = message |> String.split("<document") |> hd() |> String.length()
      proposal_at = message |> String.split("<proposal") |> hd() |> String.length()
      transcript_at = message |> String.split("<conversation") |> hd() |> String.length()

      assert document_at < proposal_at
      assert proposal_at < transcript_at
    end

    test "asks for nothing when the topic has nothing standing" do
      conversation = insert(:conversation)

      expect(ConversationsMock, :recent_messages, fn _conversation, _limit -> [] end)
      expect(DocumentsMock, :live_conversation_proposals, fn _id -> [] end)

      assert {:ok, %{message: message}} =
               PromptBuilder.build("first thing", [], replay: conversation)

      refute message =~ "<proposal"
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

  describe "build/3 failures" do
    test "names every reference that no longer exists, not just the first" do
      gone = UUIDv7.generate()
      also_gone = UUIDv7.generate()

      expect(DocumentsMock, :get_document!, 2, fn _id ->
        raise Ecto.NoResultsError, queryable: RintoPMO.Documents.Document
      end)

      # Being asked once per broken reference is not a choice, it is an
      # interrogation, so the caller gets the whole list at once.
      assert {:error, :ref_not_found, %{"refs" => refs}} =
               PromptBuilder.build("hi", [
                 %{"type" => "document", "id" => gone},
                 %{"type" => "document", "id" => also_gone}
               ])

      assert Enum.map(refs, & &1["id"]) == [gone, also_gone]
    end

    test "sends the rest with a marker once a human has chosen to skip" do
      good = document_with_blocks(["Content"])
      gone = UUIDv7.generate()

      expect(DocumentsMock, :get_document!, 2, fn id ->
        if id == good.id do
          good
        else
          raise Ecto.NoResultsError, queryable: RintoPMO.Documents.Document
        end
      end)

      assert {:ok, %{message: message}} =
               PromptBuilder.build(
                 "hi",
                 [
                   %{"type" => "document", "id" => good.id},
                   %{"type" => "document", "id" => gone}
                 ],
                 on_missing_refs: :skip
               )

      assert message =~ "Content"
      # Not removed outright: the model would otherwise face "tighten this
      # paragraph" with no paragraph and no sign one was ever meant to be there.
      assert message =~ ~s(<reference ref="2" status="unavailable" type="document" id="#{gone}">)
      assert message =~ "No longer available."
    end

    test "refuses a malformed ref even when skipping is allowed" do
      # A reference whose target has gone is ordinary; one the client built
      # wrong is a bug, and skipping it would hide it.
      assert {:error, :invalid_ref, _details} =
               PromptBuilder.build("hi", [%{"type" => "wormhole", "id" => "whatever"}],
                 on_missing_refs: :skip
               )
    end

    test "stops on a malformed ref rather than sending a partial prompt" do
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

  defp replayed_message(conversation, role, position, content, refs) do
    build(:message,
      conversation: conversation,
      role: role,
      position: position,
      content: content,
      refs: refs
    )
  end

  defp message_ref_for(document) do
    build(:message_ref,
      message: nil,
      ref_type: "document",
      ref_id: document.id,
      payload: %{"type" => "document", "id" => document.id}
    )
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
