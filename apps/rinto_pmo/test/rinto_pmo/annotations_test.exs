defmodule RintoPMO.AnnotationsTest do
  use RintoPMO.DataCase, async: true

  use Oban.Testing, repo: RintoPMO.Repo

  alias RintoPMO.Agent.AnnotationResponderMock
  alias RintoPMO.Annotations
  alias RintoPMO.Annotations.Annotation
  alias RintoPMO.Annotations.ReplyWorker
  alias RintoPMO.Documents.Notifier
  alias RintoPMO.DocumentsMock
  alias RintoPMO.Settings

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

  describe "an AI reply, when somebody asks for one" do
    setup do
      actor =
        insert(:actor, kind: :ai, provider: "google", model: "flash", thinking_level: "off")

      {:ok, _settings} = Settings.put_actor("annotation_actor", actor.id)
      {:ok, actor: actor}
    end

    test "answers with the job and leaves the model call to the queue" do
      annotation = insert(:annotation)

      assert {:ok, %Oban.Job{} = job} = Annotations.request_reply(annotation)
      assert job.worker == "RintoPMO.Annotations.ReplyWorker"

      assert_enqueued(worker: ReplyWorker, args: %{annotation_id: annotation.id})
    end

    # A double-click is one reply. Not refused, and not a second model call:
    # the caller is handed the job already queued.
    test "a second ask while one is in flight is the same job" do
      annotation = insert(:annotation)

      assert {:ok, first} = Annotations.request_reply(annotation)
      assert {:ok, second} = Annotations.request_reply(annotation)

      assert second.id == first.id
      assert second.conflict?
      assert 1 == length(all_enqueued(worker: ReplyWorker))
    end

    # Nobody holding the role is a condition of asking, so it is answered
    # synchronously to whoever is making the mistake -- not a job that queues
    # and then fails somewhere they are not looking.
    test "refuses when no actor holds the role" do
      {:ok, _cleared} = Settings.put_actor("annotation_actor", nil)
      annotation = insert(:annotation)

      assert {:error, :no_annotation_actor, %{}} = Annotations.request_reply(annotation)
      assert [] == all_enqueued(worker: ReplyWorker)
    end

    # Somebody may well want the model's read on a decision already taken.
    # Refusing would mean this context had an opinion about why they asked.
    test "does not refuse a confirmed annotation" do
      annotation = insert(:annotation)
      {:ok, confirmed} = Annotations.confirm_annotation(annotation, %{})

      assert {:ok, %Oban.Job{}} = Annotations.request_reply(confirmed)
    end

    test "appends the model's answer as an ordinary reply, credited to the AI actor" do
      %{actor: actor} = ai_context()
      annotation = insert(:annotation)
      stub_document(annotation)

      expect(AnnotationResponderMock, :respond, fn _input, _opts ->
        {:ok, "The objection is right: §3 contradicts §1."}
      end)

      assert :ok = Annotations.run_reply(1, annotation.id)

      assert [reply] = Repo.preload(annotation, :replies).replies
      assert reply.content == "The objection is right: §3 contradicts §1."
      assert reply.actor_id == actor.id
      assert reply.position == 0
    end

    test "the model is given the note, what is already under it, and the document" do
      ai_context()
      block = insert(:document_block, content: "Deploys are rolled back in one step.")
      revision = insert(:document_revision, blocks: [block])
      annotation = insert(:annotation, document: revision.document, selected_text: "one step")
      other = insert(:actor)

      {:ok, _earlier} =
        Annotations.create_reply(annotation, %{actor_id: other.id, content: "I disagree."})

      stub_document(annotation)

      expect(AnnotationResponderMock, :respond, fn input, _opts ->
        assert input.annotation.content == annotation.content
        assert input.annotation.selected_text == "one step"
        assert input.annotation.replies == ["I disagree."]
        assert input.document.blocks == ["Deploys are rolled back in one step."]
        {:ok, "Answered."}
      end)

      assert :ok = Annotations.run_reply(1, annotation.id)
    end

    test "tells whoever is watching the document that it is over" do
      ai_context()
      annotation = insert(:annotation)
      stub_document(annotation)
      :ok = Notifier.subscribe(annotation.document_id)

      expect(AnnotationResponderMock, :respond, fn _input, _opts -> {:ok, "Answered."} end)

      assert :ok = Annotations.run_reply(7, annotation.id)

      assert_receive {:annotation_reply, 7, annotation_id, :succeeded, nil}
      assert annotation_id == annotation.id
    end

    # `:cancel` and not `:error`: asking the identical question nineteen more
    # times is nineteen more model calls, not a retry policy.
    test "a failed model call cancels the job and says why on the socket" do
      ai_context()
      annotation = insert(:annotation)
      stub_document(annotation)
      :ok = Notifier.subscribe(annotation.document_id)

      expect(AnnotationResponderMock, :respond, fn _input, _opts ->
        {:error, {:provider_refused, "quota exhausted"}}
      end)

      assert {:cancel, "quota exhausted"} = Annotations.run_reply(9, annotation.id)

      assert_receive {:annotation_reply, 9, _id, :failed, "quota exhausted"}
      assert [] == Repo.preload(annotation, :replies).replies
    end

    # Deleted while the job waited. There is nothing to answer and no thread
    # left to answer into, so this is over rather than failed.
    test "an annotation deleted before the job ran is not an error" do
      assert :ok = Annotations.run_reply(1, UUIDv7.generate())
    end

    test "the role being cleared between asking and running fails the job" do
      annotation = insert(:annotation)
      {:ok, _cleared} = Settings.put_actor("annotation_actor", nil)

      assert {:cancel, reason} = Annotations.run_reply(1, annotation.id)
      assert reason =~ "annotation role"
    end
  end

  # The role, re-read inside a test that also needs the actor struct back.
  defp ai_context do
    actor = Settings.get_actor("annotation_actor")
    %{actor: actor}
  end

  # `run_reply/2` reads the document through the injector, so a test of it has
  # to say what that read answers.
  defp stub_document(annotation) do
    document =
      RintoPMO.Repo.get!(RintoPMO.Documents.Document, annotation.document_id)
      |> then(&%{&1 | latest_revision: latest_revision(&1)})

    stub(DocumentsMock, :get_document!, fn _id -> document end)
  end

  defp latest_revision(document) do
    import Ecto.Query

    RintoPMO.Documents.DocumentRevision
    |> where([revision], revision.document_id == ^document.id)
    |> order_by([revision], desc: revision.id)
    |> limit(1)
    |> RintoPMO.Repo.one()
    |> case do
      nil -> %RintoPMO.Documents.DocumentRevision{title: "Untitled", blocks: []}
      revision -> RintoPMO.Repo.preload(revision, :blocks)
    end
  end

  defp annotation_ids(annotations) do
    annotations |> Enum.map(& &1.id) |> MapSet.new()
  end
end
