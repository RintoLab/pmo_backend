defmodule RintoPMO.AnnotationsTest do
  use RintoPMO.DataCase, async: true

  alias RintoPMO.Annotations
  alias RintoPMO.Annotations.Annotation

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

  describe "status" do
    test "starts open" do
      document = insert(:document)
      actor = insert(:actor)

      assert {:ok, annotation} =
               Annotations.create_annotation(document, %{actor_id: actor.id, content: "Note"})

      assert annotation.status == :open
      assert annotation.resolved_by_revision_id == nil
    end

    test "round-trips resolve, reopen, resolve and clears the revision on reopen" do
      annotation = insert(:annotation)
      revision = insert(:document_revision, document: annotation.document)

      assert {:ok, resolved} =
               Annotations.resolve_annotation(annotation, %{
                 resolved_by_revision_id: revision.id
               })

      assert resolved.status == :resolved
      assert resolved.resolved_by_revision_id == revision.id

      assert {:ok, reopened} = Annotations.reopen_annotation(resolved)
      assert reopened.status == :open
      assert reopened.resolved_by_revision_id == nil

      assert {:ok, resolved_again} = Annotations.resolve_annotation(reopened, %{})
      assert resolved_again.status == :resolved
      assert resolved_again.resolved_by_revision_id == nil
    end

    test "resolves without naming a revision" do
      annotation = insert(:annotation)

      assert {:ok, resolved} = Annotations.resolve_annotation(annotation, %{})
      assert resolved.status == :resolved
      assert resolved.resolved_by_revision_id == nil
    end

    test "dismisses an annotation" do
      annotation = insert(:annotation)

      assert {:ok, dismissed} = Annotations.dismiss_annotation(annotation)
      assert dismissed.status == :dismissed

      assert {:ok, reopened} = Annotations.reopen_annotation(dismissed)
      assert reopened.status == :open
    end

    test "rejects a resolving revision that does not exist" do
      annotation = insert(:annotation)

      assert {:error, changeset} =
               Annotations.resolve_annotation(annotation, %{
                 resolved_by_revision_id: UUIDv7.generate()
               })

      assert "does not exist" in errors_on(changeset).resolved_by_revision_id
    end

    test "update_annotation cannot change status" do
      annotation = insert(:annotation)

      assert {:ok, updated} =
               Annotations.update_annotation(annotation, %{
                 "content" => "New",
                 "status" => "resolved"
               })

      assert updated.content == "New"
      assert updated.status == :open
      assert Repo.get!(Annotation, annotation.id).status == :open
    end

    test "create_annotation cannot set a status other than open" do
      document = insert(:document)
      actor = insert(:actor)

      assert {:ok, annotation} =
               Annotations.create_annotation(document, %{
                 "actor_id" => actor.id,
                 "content" => "Note",
                 "status" => "resolved"
               })

      assert annotation.status == :open
    end

    test "filters the list by status" do
      document = insert(:document)
      actor = insert(:actor)

      {:ok, open} =
        Annotations.create_annotation(document, %{actor_id: actor.id, content: "Open"})

      {:ok, to_resolve} =
        Annotations.create_annotation(document, %{actor_id: actor.id, content: "Resolved"})

      {:ok, to_dismiss} =
        Annotations.create_annotation(document, %{actor_id: actor.id, content: "Dismissed"})

      {:ok, resolved} = Annotations.resolve_annotation(to_resolve, %{})
      {:ok, dismissed} = Annotations.dismiss_annotation(to_dismiss)

      assert annotation_ids(Annotations.list_annotations(document, %{status: :open})) ==
               MapSet.new([open.id])

      assert annotation_ids(Annotations.list_annotations(document, %{status: :resolved})) ==
               MapSet.new([resolved.id])

      assert annotation_ids(Annotations.list_annotations(document, %{status: :dismissed})) ==
               MapSet.new([dismissed.id])

      assert annotation_ids(Annotations.list_annotations(document, %{})) ==
               MapSet.new([open.id, resolved.id, dismissed.id])
    end

    test "combines the status and block_id filters" do
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
          content: "Anchored resolved"
        })

      {:ok, _resolved} = Annotations.resolve_annotation(anchored_other, %{})

      {:ok, _unanchored} =
        Annotations.create_annotation(document, %{actor_id: actor.id, content: "Unanchored"})

      assert annotation_ids(
               Annotations.list_annotations(document, %{block_id: block_id, status: :open})
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

  describe "conclusions from a conversation" do
    test "a reply can point back at the message it came from" do
      annotation = insert(:annotation)
      actor = insert(:actor)
      message = insert(:message)

      assert {:ok, reply} =
               Annotations.create_reply(annotation, %{
                 actor_id: actor.id,
                 content: "§3 contradicts §1; rewrite the second clause.",
                 source_message_id: message.id
               })

      assert reply.source_message_id == message.id
    end

    test "a reply without a source is still fine" do
      annotation = insert(:annotation)
      actor = insert(:actor)

      assert {:ok, reply} =
               Annotations.create_reply(annotation, %{actor_id: actor.id, content: "Mine"})

      assert reply.source_message_id == nil
    end

    test "rejects a source message that does not exist" do
      annotation = insert(:annotation)
      actor = insert(:actor)

      assert {:error, changeset} =
               Annotations.create_reply(annotation, %{
                 actor_id: actor.id,
                 content: "From nowhere",
                 source_message_id: UUIDv7.generate()
               })

      assert "does not exist" in errors_on(changeset).source_message_id
    end

    test "filters to the annotations with a conclusion waiting on a decision" do
      document = insert(:document)
      actor = insert(:actor)

      waiting = insert(:annotation, document: document, status: :open)
      quiet = insert(:annotation, document: document, status: :open)
      decided = insert(:annotation, document: document, status: :resolved)

      for annotation <- [waiting, decided] do
        {:ok, _reply} =
          Annotations.create_reply(annotation, %{
            actor_id: actor.id,
            content: "Concluded",
            source_message_id: insert(:message).id
          })
      end

      # A reply with no conversation behind it is somebody's own opinion, not
      # a conclusion the AI is handing over.
      {:ok, _reply} =
        Annotations.create_reply(quiet, %{actor_id: actor.id, content: "Just a thought"})

      assert annotation_ids(Annotations.list_annotations(document, %{pending_conclusion: true})) ==
               MapSet.new([waiting.id])

      assert annotation_ids(Annotations.list_annotations(document, %{pending_conclusion: false})) ==
               MapSet.new([quiet.id, decided.id])
    end

    test "resolving clears the pending marker without anything being read" do
      document = insert(:document)
      actor = insert(:actor)
      annotation = insert(:annotation, document: document, status: :open)

      {:ok, _reply} =
        Annotations.create_reply(annotation, %{
          actor_id: actor.id,
          content: "Concluded",
          source_message_id: insert(:message).id
        })

      assert annotation_ids(Annotations.list_annotations(document, %{pending_conclusion: true})) ==
               MapSet.new([annotation.id])

      {:ok, _resolved} = Annotations.resolve_annotation(annotation, %{})

      assert Annotations.list_annotations(document, %{pending_conclusion: true}) == []
    end
  end

  defp annotation_ids(annotations) do
    annotations |> Enum.map(& &1.id) |> MapSet.new()
  end
end
