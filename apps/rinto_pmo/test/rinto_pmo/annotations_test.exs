defmodule RintoPMO.AnnotationsTest do
  use RintoPMO.DataCase, async: true

  use Oban.Testing, repo: RintoPMO.Repo

  alias RintoPMO.Agent.AnnotationResponderMock
  alias RintoPMO.Agent.DocumentReviewer
  alias RintoPMO.Agent.DocumentReviewerMock
  alias RintoPMO.Annotations
  alias RintoPMO.Annotations.Annotation
  alias RintoPMO.Annotations.ReplyWorker
  alias RintoPMO.Annotations.ReviewWorker
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

  describe "an AI review, when somebody asks for one" do
    setup do
      actor =
        insert(:actor,
          kind: :ai,
          provider: "google",
          model: "flash",
          thinking_level: "off",
          system_prompt: "Prioritise operational safety and rollback risks."
        )

      {:ok, _settings} = Settings.put_actor("review_actor", actor.id)
      {:ok, actor: actor}
    end

    test "answers with the job, and the set is its key" do
      first = insert(:document)
      second = insert(:document)
      sorted = Enum.sort([first.id, second.id])

      assert {:ok, %Oban.Job{} = job} = Annotations.request_review([first, second])
      assert job.worker == "RintoPMO.Annotations.ReviewWorker"

      assert_enqueued(worker: ReviewWorker, args: %{document_ids: sorted})
    end

    # The same selection is the same question however the client ordered it,
    # and asking for the same document twice is asking about it once.
    test "order and duplicates do not make a second review" do
      first = insert(:document)
      second = insert(:document)

      assert {:ok, one} = Annotations.request_review([first, second])
      assert {:ok, two} = Annotations.request_review([second, first, first])

      assert two.id == one.id
      assert two.conflict?
      assert 1 == length(all_enqueued(worker: ReviewWorker))
    end

    test "refuses a review of nothing" do
      assert {:error, :no_documents, %{}} = Annotations.request_review([])
      assert [] == all_enqueued(worker: ReviewWorker)
    end

    # Refused rather than trimmed: a caller handed a smaller review than it
    # asked for concludes the rest was clean.
    test "refuses more documents than one review carries" do
      documents =
        for _over_the_limit <- 1..(Annotations.max_documents() + 1), do: insert(:document)

      assert {:error, :too_many_documents, %{limit: limit}} =
               Annotations.request_review(documents)

      assert limit == Annotations.max_documents()
      assert [] == all_enqueued(worker: ReviewWorker)
    end

    test "refuses when no actor holds the role" do
      {:ok, _cleared} = Settings.put_actor("review_actor", nil)

      assert {:error, :no_review_actor, %{}} =
               Annotations.request_review([insert(:document)])

      assert [] == all_enqueued(worker: ReviewWorker)
    end

    test "the model is given every document, with block ids to name them back by" do
      review_context()
      document = reviewable("Deploys", ["Rolled back in one step.", "Two machines."])
      other = reviewable("Rollbacks", ["Rolled back by redeploying."])
      stub_documents([document, other])

      expect(DocumentReviewerMock, :review, fn input, opts ->
        assert [first, second] = Enum.sort_by(input.documents, & &1.title)
        assert first.title == "Deploys"
        assert second.title == "Rollbacks"

        assert Enum.map(first.blocks, & &1.text) == [
                 "Rolled back in one step.",
                 "Two machines."
               ]

        assert Enum.map(first.blocks, & &1.id) ==
                 Enum.map(document.latest_revision.blocks, & &1.block_id)

        assert opts[:provider] == "google"
        assert opts[:model] == "flash"
        assert opts[:thinking] == "off"
        assert opts[:system_prompt] == "Prioritise operational safety and rollback risks."

        {:ok, []}
      end)

      assert :ok = Annotations.run_review(1, [document.id, other.id])
    end

    test "writes each finding as an annotation on the document it names" do
      %{actor: actor} = review_context()
      document = reviewable("Deploys", ["Rolled back in one step."])
      other = reviewable("Rollbacks", ["Rolled back by redeploying."])
      stub_documents([document, other])
      [block] = document.latest_revision.blocks

      expect(DocumentReviewerMock, :review, fn _input, _opts ->
        {:ok,
         [
           %{
             "document_id" => document.id,
             "block_id" => block.block_id,
             "content" => "This contradicts the rollback document."
           }
         ]}
      end)

      assert :ok = Annotations.run_review(1, [document.id, other.id])

      assert [annotation] = Annotations.list_annotations(document, %{})
      assert annotation.content == "This contradicts the rollback document."
      assert annotation.actor_id == actor.id
      assert annotation.block_id == block.block_id
      # The anchor snapshot comes from the block, not from the model: it is a
      # fact about the revision rather than something a finding gets to assert.
      assert annotation.block_text == "Rolled back in one step."
      assert [] == Annotations.list_annotations(other, %{})
    end

    # The text still names what it is about. A finding thrown away for a bad
    # pointer is the one thing worse than a finding with no pin in the margin.
    test "a block id that is not there leaves the note unanchored" do
      review_context()
      document = reviewable("Deploys", ["Rolled back in one step."])
      stub_documents([document])

      expect(DocumentReviewerMock, :review, fn _input, _opts ->
        {:ok,
         [
           %{
             "document_id" => document.id,
             "block_id" => UUIDv7.generate(),
             "content" => "The second section says otherwise."
           }
         ]}
      end)

      assert :ok = Annotations.run_review(1, [document.id])

      assert [annotation] = Annotations.list_annotations(document, %{})
      assert annotation.block_id == nil
      assert annotation.block_text == nil
    end

    test "a finding naming a document outside the set is dropped" do
      review_context()
      document = reviewable("Deploys", ["Rolled back in one step."])
      elsewhere = insert(:document)
      stub_documents([document])

      expect(DocumentReviewerMock, :review, fn _input, _opts ->
        {:ok,
         [
           %{"document_id" => elsewhere.id, "block_id" => nil, "content" => "Nowhere to put it."},
           %{"document_id" => document.id, "block_id" => nil, "content" => "This one lands."}
         ]}
      end)

      assert :ok = Annotations.run_review(1, [document.id])

      assert [annotation] = Annotations.list_annotations(document, %{})
      assert annotation.content == "This one lands."
      assert [] == Annotations.list_annotations(elsewhere, %{})
    end

    # A model that invents one reference should not cost somebody the notes it
    # got right. The write path refuses the dead link exactly as it would a
    # person's, and only that note is lost.
    test "a note the write path refuses does not take the others down" do
      review_context()
      document = reviewable("Deploys", ["Rolled back in one step."])
      stub_documents([document])

      expect(DocumentReviewerMock, :review, fn _input, _opts ->
        {:ok,
         [
           %{
             "document_id" => document.id,
             "block_id" => nil,
             "content" => "See [that](rinto://document/#{UUIDv7.generate()})."
           },
           %{"document_id" => document.id, "block_id" => nil, "content" => "This one lands."}
         ]}
      end)

      assert :ok = Annotations.run_review(1, [document.id])

      assert [annotation] = Annotations.list_annotations(document, %{})
      assert annotation.content == "This one lands."
    end

    # The prompt asks for a cap and this enforces one, because a prompt is a
    # request rather than a constraint.
    test "more findings than the cap are cut off" do
      review_context()
      document = reviewable("Deploys", ["Rolled back in one step."])
      stub_documents([document])
      over = DocumentReviewer.max_findings() + 5

      expect(DocumentReviewerMock, :review, fn _input, _opts ->
        {:ok,
         for index <- 1..over do
           %{"document_id" => document.id, "block_id" => nil, "content" => "Finding #{index}"}
         end}
      end)

      assert :ok = Annotations.run_review(1, [document.id])

      assert DocumentReviewer.max_findings() ==
               length(Annotations.list_annotations(document, %{}))
    end

    test "every document in the review is told, with what landed on it" do
      review_context()
      document = reviewable("Deploys", ["Rolled back in one step."])
      other = reviewable("Rollbacks", ["Rolled back by redeploying."])
      stub_documents([document, other])
      :ok = Notifier.subscribe(document.id)
      :ok = Notifier.subscribe(other.id)

      expect(DocumentReviewerMock, :review, fn _input, _opts ->
        {:ok,
         [%{"document_id" => document.id, "block_id" => nil, "content" => "One thing is wrong."}]}
      end)

      assert :ok = Annotations.run_review(7, [document.id, other.id])

      assert_receive {:document_review, 7, first_id, :succeeded, nil, 1}
      assert first_id == document.id
      assert_receive {:document_review, 7, second_id, :succeeded, nil, 0}
      assert second_id == other.id
    end

    test "a failed model call cancels the job and says why on every document" do
      review_context()
      document = reviewable("Deploys", ["Rolled back in one step."])
      stub_documents([document])
      :ok = Notifier.subscribe(document.id)

      expect(DocumentReviewerMock, :review, fn _input, _opts ->
        {:error, {:provider_refused, "quota exhausted"}}
      end)

      assert {:cancel, "quota exhausted"} = Annotations.run_review(9, [document.id])

      assert_receive {:document_review, 9, _id, :failed, "quota exhausted", 0}
      assert [] == Annotations.list_annotations(document, %{})
    end

    test "an answer that is not a list of findings fails the job" do
      review_context()
      document = reviewable("Deploys", ["Rolled back in one step."])
      stub_documents([document])

      expect(DocumentReviewerMock, :review, fn _input, _opts -> {:error, :invalid_output} end)

      assert {:cancel, reason} = Annotations.run_review(1, [document.id])
      assert reason =~ "list of findings"
    end

    # Deleted while the job waited. There is nothing to review and nowhere to
    # say so, which is over rather than failed.
    test "documents deleted before the job ran are not an error" do
      stub_documents([])

      assert :ok = Annotations.run_review(1, [UUIDv7.generate()])
    end

    test "the role being cleared between asking and running fails the job" do
      document = reviewable("Deploys", ["Rolled back in one step."])
      stub_documents([document])
      {:ok, _cleared} = Settings.put_actor("review_actor", nil)

      assert {:cancel, reason} = Annotations.run_review(1, [document.id])
      assert reason =~ "review role"
    end
  end

  # A document as `run_review/2` reads it: through the injector, with its
  # latest revision and blocks already on it.
  defp reviewable(title, texts) do
    blocks =
      texts
      |> Enum.with_index()
      |> Enum.map(fn {text, position} ->
        insert(:document_block, content: text, position: position)
      end)

    revision = insert(:document_revision, title: title, blocks: blocks)

    %{revision.document | latest_revision: RintoPMO.Repo.preload(revision, :blocks)}
  end

  defp stub_documents(documents) do
    by_id = Map.new(documents, &{&1.id, &1})

    stub(DocumentsMock, :get_document!, fn id ->
      case Map.fetch(by_id, id) do
        {:ok, document} -> document
        :error -> raise Ecto.NoResultsError, queryable: RintoPMO.Documents.Document
      end
    end)
  end

  # The role, re-read inside a test that also needs the actor struct back.
  defp ai_context do
    actor = Settings.get_actor("annotation_actor")
    %{actor: actor}
  end

  defp review_context do
    actor = Settings.get_actor("review_actor")
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
