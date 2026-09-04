defmodule RintoPMO.AnnotationsTest do
  use RintoPMO.DataCase, async: true

  use Oban.Testing, repo: RintoPMO.Repo

  alias RintoPMO.Actors
  alias RintoPMO.ActorsMock
  alias RintoPMO.Annotations
  alias RintoPMO.Annotations.Annotation
  alias RintoPMO.Projects
  alias RintoPMO.ProjectsMock

  describe "annotations" do
    test "creates an annotation with optional anchor snapshots" do
      document = insert(:document)
      actor = insert(:actor)
      block_id = UUIDv7.generate()

      assert {:ok, %Annotation{} = annotation} =
               Annotations.create_annotation(document, %{
                 actor_id: actor.id,
                 block_id: block_id,
                 block_text: "Full block body",
                 selected_text: "selected slice",
                 content: "Please tighten this"
               })

      assert annotation.document_id == document.id
      assert annotation.actor_id == actor.id
      assert annotation.block_id == block_id
      assert annotation.block_text == "Full block body"
      assert annotation.selected_text == "selected slice"
      assert annotation.content == "Please tighten this"
    end

    test "requires actor and content" do
      document = insert(:document)

      assert {:error, changeset} = Annotations.create_annotation(document, %{})
      assert "can't be blank" in errors_on(changeset).actor_id
      assert "can't be blank" in errors_on(changeset).content
    end

    test "rejects blank annotation content" do
      document = insert(:document)
      actor = insert(:actor)

      assert {:error, changeset} =
               Annotations.create_annotation(document, %{actor_id: actor.id, content: ""})

      assert content_errors = errors_on(changeset).content

      assert "can't be blank" in content_errors or
               Enum.any?(content_errors, &String.contains?(&1, "at least"))
    end

    test "lists annotations without replies and filters by block_id" do
      document = insert(:document)
      other = insert(:document)
      actor = insert(:actor)
      block_id = UUIDv7.generate()

      {:ok, matched} =
        Annotations.create_annotation(document, %{
          actor_id: actor.id,
          block_id: block_id,
          content: "Matched"
        })

      {:ok, unanchored} =
        Annotations.create_annotation(document, %{
          actor_id: actor.id,
          content: "Unanchored"
        })

      {:ok, _other_doc} =
        Annotations.create_annotation(other, %{
          actor_id: actor.id,
          content: "Other document"
        })

      assert annotation_ids(Annotations.list_annotations(document, %{})) ==
               MapSet.new([matched.id, unanchored.id])

      assert annotation_ids(Annotations.list_annotations(document, %{block_id: block_id})) ==
               MapSet.new([matched.id])

      assert annotation_ids(Annotations.list_annotations(document, %{block_id: nil})) ==
               MapSet.new([unanchored.id])

      listed = Annotations.list_annotations(document, %{})
      assert Enum.all?(listed, &(not Ecto.assoc_loaded?(&1.replies)))
    end

    test "updates content and deletes the annotation" do
      annotation = insert(:annotation, content: "Old")

      assert {:ok, updated} =
               Annotations.update_annotation(annotation, %{content: "New"})

      assert updated.content == "New"

      assert {:ok, deleted} = Annotations.delete_annotation(updated)
      assert deleted.id == annotation.id

      assert_raise Ecto.NoResultsError, fn ->
        Annotations.get_annotation!(annotation.document, annotation.id)
      end
    end
  end

  describe "confirmation" do
    test "starts unconfirmed" do
      document = insert(:document)
      actor = insert(:actor)

      assert {:ok, annotation} =
               Annotations.create_annotation(document, %{actor_id: actor.id, content: "Note"})

      assert annotation.confirmed_at == nil
      assert annotation.confirmed_by_revision_id == nil
    end

    test "round-trips confirm, unconfirm, confirm and clears the revision on the way back" do
      annotation = insert(:annotation)
      revision = insert(:document_revision, document: annotation.document)

      assert {:ok, confirmed} =
               Annotations.confirm_annotation(annotation, %{
                 confirmed_by_revision_id: revision.id
               })

      assert confirmed.confirmed_at
      assert confirmed.confirmed_by_revision_id == revision.id

      assert {:ok, reopened} = Annotations.unconfirm_annotation(confirmed)
      assert reopened.confirmed_at == nil
      assert reopened.confirmed_by_revision_id == nil

      assert {:ok, again} = Annotations.confirm_annotation(reopened, %{})
      assert again.confirmed_at
      assert again.confirmed_by_revision_id == nil
    end

    # "I looked and it needs no change" is a confirmation like any other.
    # Which of the two it was is the pointer's presence, not a second state.
    test "confirms without naming a revision" do
      annotation = insert(:annotation)

      assert {:ok, confirmed} = Annotations.confirm_annotation(annotation, %{})
      assert confirmed.confirmed_at
      assert confirmed.confirmed_by_revision_id == nil
    end

    test "confirming twice keeps the moment it was first confirmed" do
      annotation = insert(:annotation)
      revision = insert(:document_revision, document: annotation.document)

      {:ok, first} = Annotations.confirm_annotation(annotation, %{})

      # Naming the revision afterwards is not a second ending.
      assert {:ok, second} =
               Annotations.confirm_annotation(first, %{confirmed_by_revision_id: revision.id})

      assert second.confirmed_at == first.confirmed_at
      assert second.confirmed_by_revision_id == revision.id
    end

    test "unconfirming clears both columns in the database" do
      annotation = insert(:annotation)
      revision = insert(:document_revision, document: annotation.document)

      {:ok, confirmed} =
        Annotations.confirm_annotation(annotation, %{confirmed_by_revision_id: revision.id})

      assert {:ok, _reopened} = Annotations.unconfirm_annotation(confirmed)

      stored = Repo.get!(Annotation, annotation.id)
      assert stored.confirmed_at == nil
      assert stored.confirmed_by_revision_id == nil
    end

    test "rejects a confirming revision that does not exist" do
      annotation = insert(:annotation)

      assert {:error, changeset} =
               Annotations.confirm_annotation(annotation, %{
                 confirmed_by_revision_id: UUIDv7.generate()
               })

      assert "does not exist" in errors_on(changeset).confirmed_by_revision_id
    end

    # Editing the wording must never be able to close a thread.
    test "update_annotation cannot confirm" do
      annotation = insert(:annotation)

      assert {:ok, updated} =
               Annotations.update_annotation(annotation, %{
                 "content" => "New",
                 "confirmed_at" => DateTime.utc_now()
               })

      assert updated.content == "New"
      assert updated.confirmed_at == nil
      assert Repo.get!(Annotation, annotation.id).confirmed_at == nil
    end

    test "create_annotation cannot arrive confirmed" do
      document = insert(:document)
      actor = insert(:actor)

      assert {:ok, annotation} =
               Annotations.create_annotation(document, %{
                 "actor_id" => actor.id,
                 "content" => "Note",
                 "confirmed_at" => DateTime.utc_now()
               })

      assert annotation.confirmed_at == nil
    end

    test "filters the list by whether it has been confirmed" do
      document = insert(:document)
      actor = insert(:actor)

      {:ok, open} =
        Annotations.create_annotation(document, %{actor_id: actor.id, content: "Open"})

      {:ok, to_confirm} =
        Annotations.create_annotation(document, %{actor_id: actor.id, content: "Settled"})

      {:ok, confirmed} = Annotations.confirm_annotation(to_confirm, %{})

      assert annotation_ids(Annotations.list_annotations(document, %{confirmed: false})) ==
               MapSet.new([open.id])

      assert annotation_ids(Annotations.list_annotations(document, %{confirmed: true})) ==
               MapSet.new([confirmed.id])

      assert annotation_ids(Annotations.list_annotations(document, %{})) ==
               MapSet.new([open.id, confirmed.id])
    end

    test "combines the confirmed and block_id filters" do
      document = insert(:document)
      actor = insert(:actor)
      block_id = UUIDv7.generate()

      {:ok, anchored_open} =
        Annotations.create_annotation(document, %{
          actor_id: actor.id,
          block_id: block_id,
          content: "Anchored open"
        })

      {:ok, anchored_other} =
        Annotations.create_annotation(document, %{
          actor_id: actor.id,
          block_id: block_id,
          content: "Anchored settled"
        })

      {:ok, _confirmed} = Annotations.confirm_annotation(anchored_other, %{})

      {:ok, _unanchored} =
        Annotations.create_annotation(document, %{actor_id: actor.id, content: "Unanchored"})

      assert annotation_ids(
               Annotations.list_annotations(document, %{block_id: block_id, confirmed: false})
             ) == MapSet.new([anchored_open.id])
    end
  end

  describe "replies" do
    test "appends monotonic positions and does not renumber after delete" do
      annotation = insert(:annotation)
      actor = insert(:actor)

      assert {:ok, first} =
               Annotations.create_reply(annotation, %{
                 actor_id: actor.id,
                 content: "First reply"
               })

      assert {:ok, second} =
               Annotations.create_reply(annotation, %{
                 actor_id: actor.id,
                 content: "Second reply"
               })

      assert first.position == 0
      assert second.position == 1

      assert {:ok, _} = Annotations.delete_reply(first)

      assert {:ok, third} =
               Annotations.create_reply(annotation, %{
                 actor_id: actor.id,
                 content: "Third reply"
               })

      assert third.position == 2

      loaded = Annotations.get_annotation!(annotation.document, annotation.id)

      assert Enum.map(loaded.replies, &{&1.position, &1.content}) == [
               {1, "Second reply"},
               {2, "Third reply"}
             ]
    end

    test "updates reply content without changing position" do
      annotation = insert(:annotation)
      actor = insert(:actor)

      {:ok, reply} =
        Annotations.create_reply(annotation, %{actor_id: actor.id, content: "Old"})

      assert {:ok, updated} = Annotations.update_reply(reply, %{content: "New"})
      assert updated.content == "New"
      assert updated.position == 0
    end

    test "rejects blank reply content" do
      annotation = insert(:annotation)
      actor = insert(:actor)

      assert {:error, changeset} =
               Annotations.create_reply(annotation, %{actor_id: actor.id, content: ""})

      assert content_errors = errors_on(changeset).content

      assert "can't be blank" in content_errors or
               Enum.any?(content_errors, &String.contains?(&1, "at least"))
    end

    test "scopes get_reply! to the annotation" do
      annotation = insert(:annotation)
      other = insert(:annotation)
      actor = insert(:actor)

      {:ok, reply} =
        Annotations.create_reply(annotation, %{actor_id: actor.id, content: "Mine"})

      assert Annotations.get_reply!(annotation, reply.id).id == reply.id

      assert_raise Ecto.NoResultsError, fn ->
        Annotations.get_reply!(other, reply.id)
      end
    end
  end

  describe "who a note is by, and where it lands" do
    setup do
      stub_with(ActorsMock, Actors)
      # Building a document to anchor onto files it in the default project.
      stub_with(ProjectsMock, Projects)
      insert(:default_project)
      :ok
    end

    test "signs as the stand-in AI when the note comes from a topic" do
      %{document: document} = document_with_blocks(["## One\n\nText"])
      signatory = default_assistant()
      caller = insert(:actor)

      assert {:ok, annotation} =
               Annotations.create_annotation(document, %{
                 "actor_id" => caller.id,
                 "conversation_id" => Ecto.UUID.generate(),
                 "content" => "This contradicts the section above."
               })

      assert annotation.actor_id == signatory.id
      refute annotation.actor_id == caller.id
    end

    test "snapshots the block's text when the caller named a block but no text" do
      %{document: document, blocks: [block | _rest]} = document_with_blocks(["## One\n\nText"])
      default_assistant()

      assert {:ok, annotation} =
               Annotations.create_annotation(document, %{
                 "actor_id" => insert(:actor).id,
                 "block_id" => block.block_id,
                 "content" => "Wrong."
               })

      assert annotation.block_id == block.block_id
      assert annotation.block_text == block.content
    end

    # A client that captured the text when somebody highlighted it holds the
    # snapshot matching its `selected_text`. Replacing it with what the block
    # says now would leave the two describing different revisions.
    test "keeps a block_text the caller supplied" do
      %{document: document, blocks: [block | _rest]} = document_with_blocks(["## One\n\nText"])

      assert {:ok, annotation} =
               Annotations.create_annotation(document, %{
                 "actor_id" => insert(:actor).id,
                 "block_id" => block.block_id,
                 "block_text" => "what it said when I highlighted it",
                 "content" => "Wrong."
               })

      assert annotation.block_text == "what it said when I highlighted it"
    end

    test "writes the note unanchored when the block is not there" do
      %{document: document} = document_with_blocks(["## One\n\nText"])

      assert {:ok, annotation} =
               Annotations.create_annotation(document, %{
                 "actor_id" => insert(:actor).id,
                 "block_id" => Ecto.UUID.generate(),
                 "block_text" => "a block that never existed",
                 "content" => "Still worth saying."
               })

      # Dropped, not kept: an id pointing at no block claims an anchor it does
      # not have, and every reader of `block_id` would have to defend against it.
      assert annotation.block_id == nil
      assert annotation.block_text == nil
      assert annotation.content == "Still worth saying."
    end

    # Silence is not evidence. A caller holding a document whose blocks were
    # never loaded has said nothing about whether the anchor is good.
    test "leaves the anchor alone when the document's blocks were never loaded" do
      document = insert(:document)
      block_id = UUIDv7.generate()

      assert {:ok, annotation} =
               Annotations.create_annotation(document, %{
                 "actor_id" => insert(:actor).id,
                 "block_id" => block_id,
                 "content" => "Unverifiable, and kept."
               })

      assert annotation.block_id == block_id
    end
  end

  describe "who a reply is by" do
    setup do
      stub_with(ActorsMock, Actors)
      :ok
    end

    test "signs as the stand-in AI when the reply comes from a topic" do
      annotation = insert(:annotation)
      signatory = default_assistant()
      caller = insert(:actor)

      assert {:ok, reply} =
               Annotations.create_reply(annotation, %{
                 "actor_id" => caller.id,
                 "conversation_id" => Ecto.UUID.generate(),
                 "content" => "The section above already says the opposite."
               })

      assert reply.actor_id == signatory.id
      refute reply.actor_id == caller.id
    end

    test "keeps the caller when there is no topic" do
      annotation = insert(:annotation)
      default_assistant()
      caller = insert(:actor)

      assert {:ok, reply} =
               Annotations.create_reply(annotation, %{
                 "actor_id" => caller.id,
                 "content" => "I wrote this myself."
               })

      assert reply.actor_id == caller.id
    end

    # Nothing stores the topic, and signing no longer depends on which
    # assistant it was configured with, so `conversation_id` says only "a model
    # is writing this". Looking the topic up would not make that truer.
    test "does not look the topic up" do
      annotation = insert(:annotation)
      signatory = default_assistant()

      assert {:ok, reply} =
               Annotations.create_reply(annotation, %{
                 "actor_id" => insert(:actor).id,
                 "conversation_id" => Ecto.UUID.generate(),
                 "content" => "Still signed."
               })

      assert reply.actor_id == signatory.id
    end

    test "refuses when setup never made the stand-in" do
      annotation = insert(:annotation)
      conversation_id = Ecto.UUID.generate()

      assert {:error, :default_assistant_missing, details} =
               Annotations.create_reply(annotation, %{
                 "actor_id" => insert(:actor).id,
                 "conversation_id" => conversation_id,
                 "content" => "Nobody signs this."
               })

      assert details.conversation_id == conversation_id
    end
  end

  defp document_with_blocks(sections) do
    {:ok, document} =
      RintoPMO.Documents.create_document(%{
        title: "Document",
        actor_id: insert(:actor).id,
        markdown: Enum.join(sections, "\n\n")
      })

    document = RintoPMO.Documents.get_document!(document.id)
    %{document: document, blocks: document.latest_revision.blocks}
  end

  defp annotation_ids(annotations) do
    annotations |> Enum.map(& &1.id) |> MapSet.new()
  end
end
