defmodule RintoPMO.Documents.ProposalsTest do
  # Not async: every test here writes from a topic, so every one of them has to
  # insert the stand-in AI -- one row behind a partial unique index. Two async
  # transactions inserting it deadlock on that index, which is a fixture racing
  # itself rather than anything about the code under test.
  use RintoPMO.DataCase, async: false

  # Every proposal is signed by the stand-in AI, so it has to exist before any
  # of this can write.
  setup do
    default_assistant()
    :ok
  end

  alias RintoPMO.Actors
  alias RintoPMO.ActorsMock
  alias RintoPMO.Annotations
  alias RintoPMO.AnnotationsMock
  alias RintoPMO.Conversations
  alias RintoPMO.ConversationsMock
  alias RintoPMO.Documents
  alias RintoPMO.Documents.BlockProposal
  alias RintoPMO.Projects
  alias RintoPMO.ProjectsMock

  setup do
    # Publishing resolves annotations through the injected context; these tests
    # are about what actually lands in the database, so it runs for real.
    stub_with(AnnotationsMock, Annotations)
    # A proposal's author is read off the topic, so the real context answers --
    # and a plain chat sends the question on to the default actor.
    stub_with(ConversationsMock, Conversations)
    stub_with(ActorsMock, Actors)
    # A document created without a project is filed in the default one, which
    # therefore has to exist.
    stub_with(ProjectsMock, Projects)
    insert(:default_project)
    :ok
  end

  describe "propose_document/2" do
    test "a whole-body rewrite becomes the separate changes it is made of" do
      %{document: document} = document_with_blocks(["One", "Two", "Three"])
      conversation = insert(:conversation)

      assert {:ok, result} =
               propose_body(document, conversation, "## One, tighter\n\n## Three\n\n## Four")

      # A rewrite that edits a paragraph, drops another and adds a third is
      # three things a person will have three opinions about. There is no row
      # holding all of it and no id meaning "the rewrite".
      assert Enum.sort(Enum.map(result.proposals, & &1.operation)) == [:delete, :insert, :update]
      assert Enum.all?(result.proposals, &(&1.scope == :block))
      assert result.summary == %{changed: 1, added: 1, removed: 1, moved: 0}
    end

    test "an insertion names the block it is going to create" do
      %{document: document, blocks: [first | _rest]} = document_with_blocks(["One"])
      conversation = insert(:conversation)

      assert {:ok, %{proposals: [insertion]}} =
               propose_body(document, conversation, "## One\n\n## Two")

      assert insertion.operation == :insert
      assert insertion.after_block_id == first.block_id
      # Allocated at propose time, so the paragraph somebody reviews, cites in a
      # topic and then publishes is one block throughout.
      assert is_binary(insertion.block_id)

      {:ok, published} = publish(document, [insertion.id])
      assert Enum.map(blocks_of(published), & &1.block_id) == [first.block_id, insertion.block_id]
    end

    test "consecutive insertions share a run and are numbered in written order" do
      %{document: document, blocks: [first]} = document_with_blocks(["One"])
      conversation = insert(:conversation)

      assert {:ok, %{proposals: proposals}} =
               propose_body(document, conversation, "## One\n\n## Two\n\n## Three\n\n## Four")

      run = Enum.sort_by(proposals, & &1.run_ordinal)
      assert Enum.map(run, & &1.content) == ["## Two", "## Three", "## Four"]
      assert Enum.map(run, & &1.run_ordinal) == [0, 1, 2]
      assert run |> Enum.map(& &1.run_id) |> Enum.uniq() |> length() == 1
      # Every one of them names the gap, not the sibling before it: taking the
      # third without the second has to mean something.
      assert Enum.all?(run, &(&1.after_block_id == first.block_id))
    end

    test "a block that only moved keeps its id" do
      %{document: document, blocks: [one, two]} = document_with_blocks(["One", "Two"])
      conversation = insert(:conversation)

      assert {:ok, %{proposals: [move]}} =
               propose_body(document, conversation, "## Two\n\n## One")

      assert move.operation == :move
      assert move.block_id == one.block_id
      assert move.after_block_id == two.block_id
      assert is_nil(move.content)
    end

    test "re-proposing the same intent keeps the proposal it already has" do
      %{document: document} = document_with_blocks(["One", "Two"])
      conversation = insert(:conversation)
      markdown = "## One, tighter\n\n## Two"

      assert {:ok, %{proposals: [first]}} = propose_body(document, conversation, markdown)

      assert {:ok, %{proposals: [again], superseded: []}} =
               propose_body(document, conversation, markdown)

      # The same modification, so the same id -- every message citing it still
      # points at what it pointed at.
      assert again.id == first.id
    end

    test "changing its mind is a new proposal, and the old one is superseded" do
      %{document: document} = document_with_blocks(["One", "Two"])
      conversation = insert(:conversation)

      assert {:ok, %{proposals: [first]}} =
               propose_body(document, conversation, "## One, tighter\n\n## Two")

      assert {:ok, %{proposals: [second], superseded: superseded}} =
               propose_body(document, conversation, "## One, tighter still\n\n## Two")

      refute second.id == first.id
      assert superseded == [first.id]
      assert reload(first).status == :superseded
      # The words it was written with are untouched: a proposal id names one
      # modification forever, which is what a citation depends on.
      assert reload(first).content == "## One, tighter"
      assert second.supersedes_id == first.id
      refute second.staged
      assert is_nil(second.adopted_revision_id)
    end

    test "re-proposing replaces only this topic's body work" do
      %{document: document} = document_with_blocks(["One", "Two"])
      mine = insert(:conversation)
      theirs = insert(:conversation)

      {:ok, %{proposals: [_first]}} = propose_body(document, mine, "## One, mine\n\n## Two")
      {:ok, %{proposals: [other]}} = propose_body(document, theirs, "## One, theirs\n\n## Two")
      {:ok, %{proposals: [title]}} = propose_title(document, mine, "A better name")

      {:ok, %{superseded: superseded}} =
        propose_body(document, mine, "## One, mine again\n\n## Two")

      # A title is a different question, and another topic's work is not this
      # topic's to withdraw.
      refute title.id in superseded
      refute other.id in superseded
      assert reload(title).status == :live
      assert reload(other).status == :live
    end

    test "refuses a body that changes nothing" do
      %{document: document} = document_with_blocks(["One", "Two"])
      conversation = insert(:conversation)

      assert {:error, :no_change_proposed, _details} =
               propose_body(document, conversation, "## One\n\n## Two")
    end

    test "requires the revision the body was written against" do
      %{document: document} = document_with_blocks(["One"])
      conversation = insert(:conversation)

      assert {:error, :base_revision_required, _details} =
               Documents.propose_document(document, %{
                 conversation_id: conversation.id,
                 content: "## Two"
               })
    end

    test "refuses a base revision belonging to another document" do
      %{document: document} = document_with_blocks(["One"])
      %{document: other} = document_with_blocks(["Elsewhere"])
      conversation = insert(:conversation)

      assert {:error, :unknown_revision, _details} =
               Documents.propose_document(document, %{
                 conversation_id: conversation.id,
                 content: "## Two",
                 base_revision_id: latest_revision_id(other)
               })
    end

    test "compiles against the revision that was read, not the latest one" do
      %{document: document, blocks: [one, two]} = document_with_blocks(["One", "Two"])
      conversation = insert(:conversation)
      base = latest_revision_id(document)

      # Somebody else edits a different paragraph while the model is writing.
      {:ok, _revision} =
        Documents.create_revision(document, %{
          base_revision_id: base,
          block_ops: [
            %{
              op: :update,
              block_id: two.block_id,
              actor_id: insert(:actor).id,
              content: "## Two, edited"
            }
          ]
        })

      assert {:ok, %{proposals: [proposal]}} =
               Documents.propose_document(document, %{
                 conversation_id: conversation.id,
                 content: "## One, tighter\n\n## Two",
                 base_revision_id: base
               })

      # Only the paragraph the rewrite actually changed. Compiling against the
      # latest revision instead would have produced an update putting "Two"
      # back, quietly reverting the edit that landed in between.
      assert proposal.operation == :update
      assert proposal.block_id == one.block_id
      assert proposal.base_revision_id == base
    end
  end

  describe "propose_block/2 and propose_title/2" do
    test "records one block's new text, signed by the stand-in AI" do
      %{document: document, blocks: [block | _rest]} = document_with_blocks(["One", "Two"])
      conversation = insert(:conversation)

      assert {:ok, %{proposals: [proposal]}} =
               propose_block(document, block.block_id, conversation, "Tighter one")

      assert proposal.scope == :block
      assert proposal.operation == :update
      assert proposal.block_id == block.block_id
      assert proposal.content == "Tighter one"
      assert proposal.base_revision_id == latest_revision_id(document)
      assert proposal.actor_id == default_assistant().id
      refute proposal.staged
    end

    test "refuses a block the read revision does not have" do
      %{document: document} = document_with_blocks(["One"])
      conversation = insert(:conversation)

      assert {:error, :unknown_block, _details} =
               propose_block(document, UUIDv7.generate(), conversation, "Nowhere")
    end

    test "a rewrite and a move of one block stand together" do
      %{document: document, blocks: [one, _two]} = document_with_blocks(["One", "Two"])
      conversation = insert(:conversation)

      {:ok, %{proposals: [move]}} = propose_body(document, conversation, "## Two\n\n## One")

      {:ok, %{proposals: [update]}} =
        propose_block(document, one.block_id, conversation, "One, tighter")

      # Different questions about one paragraph: what it says, and where it
      # sits. One topic may hold both, and neither supersedes the other.
      assert reload(move).status == :live
      assert reload(update).status == :live
      refute BlockProposal.conflicting?(reload(move), reload(update))
    end

    test "a title is an ordinary proposal with its own slot" do
      %{document: document} = document_with_blocks(["One"])
      conversation = insert(:conversation)

      assert {:ok, %{proposals: [title]}} = propose_title(document, conversation, "A better name")
      assert title.scope == :title
      assert title.operation == :update
      assert is_nil(title.block_id)
    end

    test "refuses a title that is already the document's" do
      %{document: document} = document_with_blocks(["One"])
      conversation = insert(:conversation)

      assert {:error, :no_change_proposed, _details} =
               propose_title(document, conversation, "Document")
    end
  end

  describe "conversation_working_set/1" do
    test "returns proposal details derived against the document revision it carries" do
      %{document: document, blocks: [block]} = document_with_blocks(["One"])
      conversation = insert(:conversation)

      {:ok, %{proposals: [proposal]}} =
        propose_block(document, block.block_id, conversation, "One, tighter")

      assert [entry] = Documents.conversation_working_set(conversation.id)
      assert entry.document.latest_revision.id == latest_revision_id(document)

      assert [%{proposal: detail, contended: false}] = entry.proposals
      assert detail.proposal.id == proposal.id
      assert detail.current_revision_id == entry.document.latest_revision.id
      assert detail.state == :applicable
      refute detail.adopted
      refute detail.adoption_stale
      assert detail.conflicting_proposal_ids == []
    end
  end

  describe "stage_proposal/3" do
    test "saves what the caller says, twice over if asked" do
      %{proposal: proposal, document: document} = one_uncontested_proposal()

      assert {:ok, detail} = Documents.stage_proposal(document, proposal.id, true)
      assert detail.proposal.staged
      # Not a toggle. Saying the same thing again leaves the same state, which
      # is what makes a retry harmless.
      assert {:ok, detail} = Documents.stage_proposal(document, proposal.id, true)
      assert detail.proposal.staged

      assert {:ok, detail} = Documents.stage_proposal(document, proposal.id, false)
      refute detail.proposal.staged
    end

    test "refuses to tick something with an unsettled argument against it" do
      %{document: document, first: first} = two_competing_proposals()

      assert {:error, :unresolved_contention, details} =
               Documents.stage_proposal(document, first.id, true)

      assert details.proposal_id == first.id
    end

    test "lets the adopted candidate be ticked" do
      %{document: document, first: first} = two_competing_proposals()
      person = insert(:actor)

      {:ok, _adopted} =
        Documents.adopt_proposal(document, first.id, latest_revision_id(document), person.id)

      assert {:ok, detail} = Documents.stage_proposal(document, first.id, true)
      assert detail.proposal.staged
    end

    test "refuses to tick something that cannot be applied" do
      %{document: document, blocks: [one, _two]} = document_with_blocks(["One", "Two"])
      conversation = insert(:conversation)

      {:ok, %{proposals: [proposal]}} =
        propose_block(document, one.block_id, conversation, "One, tighter")

      delete_block(document, one.block_id)

      assert {:error, :proposal_not_applicable, details} =
               Documents.stage_proposal(document, proposal.id, true)

      assert details.reason == :target_deleted
    end

    test "a late tick cannot bring a decided proposal back" do
      %{proposal: proposal, document: document} = one_uncontested_proposal()
      person = insert(:actor)

      {:ok, _rejected} = Documents.reject_proposal(document, proposal.id, person.id, "no")

      assert {:error, :proposal_not_live, _details} =
               Documents.stage_proposal(document, proposal.id, true)

      # Unticking one is not an error, though: there is nothing left to change.
      assert {:ok, detail} = Documents.stage_proposal(document, proposal.id, false)
      refute detail.proposal.staged
    end
  end

  describe "adopt_proposal/4 and unadopt_proposal/2" do
    test "chooses one candidate and unticks the others, leaving them live" do
      %{document: document, first: first, second: second} = two_competing_proposals()
      person = insert(:actor)
      revision_id = latest_revision_id(document)

      {:ok, _staged} = force_stage(second)

      assert {:ok, detail} =
               Documents.adopt_proposal(document, first.id, revision_id, person.id)

      assert detail.adopted
      # Adopting does not tick the winner either. Choosing between versions and
      # marking what to publish are two different things a person does.
      refute detail.proposal.staged
      assert reload(first).adopted_revision_id == revision_id

      # The loser is not decided. It has lost its tick and nothing else.
      assert reload(second).status == :live
      refute reload(second).staged
    end

    test "refuses to displace a choice somebody already made" do
      %{document: document, first: first, second: second} = two_competing_proposals()
      person = insert(:actor)
      revision_id = latest_revision_id(document)

      {:ok, _adopted} = Documents.adopt_proposal(document, first.id, revision_id, person.id)

      assert {:error, :already_adopted, details} =
               Documents.adopt_proposal(document, second.id, revision_id, person.id)

      assert details.adopted_proposal_id == first.id

      # Switching is said out loud, in two steps.
      assert {:ok, _released} = Documents.unadopt_proposal(document, first.id)
      assert {:ok, detail} = Documents.adopt_proposal(document, second.id, revision_id, person.id)
      assert detail.adopted
    end

    test "un-adopting restores nothing except the choice being open again" do
      %{document: document, first: first, second: second} = two_competing_proposals()
      person = insert(:actor)
      revision_id = latest_revision_id(document)

      {:ok, _staged} = force_stage(second)
      {:ok, _adopted} = Documents.adopt_proposal(document, first.id, revision_id, person.id)
      {:ok, _released} = Documents.unadopt_proposal(document, first.id)

      # The tick the loser had before is not put back: what somebody meant to
      # publish before an argument was settled is theirs to say again.
      refute reload(second).staged
      assert reload(second).status == :live
    end

    test "refuses to adopt against a revision that is no longer current" do
      %{document: document, first: first} = two_competing_proposals()
      person = insert(:actor)
      stale = latest_revision_id(document)

      append_block(document, "## Elsewhere")

      assert {:error, :stale_document, details} =
               Documents.adopt_proposal(document, first.id, stale, person.id)

      assert details.current_revision_id == latest_revision_id(document)
    end

    test "a choice survives a change elsewhere and not a change to its own words" do
      %{document: document, first: first, block_id: block_id} = two_competing_proposals()
      person = insert(:actor)

      {:ok, _adopted} =
        Documents.adopt_proposal(document, first.id, latest_revision_id(document), person.id)

      append_block(document, "## Somewhere else entirely")
      assert detail_for(document, first.id).adopted

      rewrite_block(document, block_id, "## One, by somebody else")
      detail = detail_for(document, first.id)
      refute detail.adopted
      # Told apart from never having been adopted: one is an argument nobody
      # settled, the other is a settlement about words that have since changed.
      assert detail.adoption_stale
      assert detail.state == :needs_confirmation
    end
  end

  describe "reject_proposal/4" do
    test "records a refusal that un-adopting does not undo" do
      %{document: document, first: first, second: second} = two_competing_proposals()
      person = insert(:actor)
      revision_id = latest_revision_id(document)

      assert {:ok, detail} =
               Documents.reject_proposal(document, second.id, person.id, "wrong tone")

      assert detail.proposal.status == :rejected
      assert detail.proposal.decided_reason == "wrong tone"
      assert detail.proposal.decided_by_actor_id == person.id

      {:ok, _adopted} = Documents.adopt_proposal(document, first.id, revision_id, person.id)
      {:ok, _released} = Documents.unadopt_proposal(document, first.id)

      # Somebody meant it. Reopening the argument does not un-mean it.
      assert reload(second).status == :rejected
    end
  end

  describe "contentions/1" do
    test "answers with pairs, and does not make a group out of them" do
      %{document: document, blocks: [one, _two]} = document_with_blocks(["One", "Two"])
      first = insert(:conversation)
      second = insert(:conversation)
      third = insert(:conversation)

      {:ok, %{proposals: [update]}} = propose_block(document, one.block_id, first, "One, tighter")
      {:ok, %{proposals: [move]}} = propose_body(document, second, "## Two\n\n## One")
      {:ok, %{proposals: [delete]}} = propose_body(document, third, "## Two")

      pairs = Enum.map(Documents.contentions(document), &{Enum.sort(&1.proposal_ids), &1.reason})

      # The deletion argues with both the rewrite and the move. The rewrite and
      # the move do not argue with each other, which is the whole point of not
      # collecting these into a group.
      assert Enum.sort(pairs) ==
               Enum.sort([
                 {Enum.sort([update.id, delete.id]), :competing_deletion},
                 {Enum.sort([move.id, delete.id]), :competing_deletion}
               ])
    end

    test "two titles are an ordinary argument" do
      %{document: document} = document_with_blocks(["One"])

      {:ok, %{proposals: [first]}} = propose_title(document, insert(:conversation), "One name")
      {:ok, %{proposals: [second]}} = propose_title(document, insert(:conversation), "Another")

      assert [%{reason: :competing_title, proposal_ids: ids, scope: :title}] =
               Documents.contentions(document)

      assert Enum.sort(ids) == Enum.sort([first.id, second.id])
    end

    test "insertions into one gap compete unless they were written together" do
      %{document: document, blocks: [one]} = document_with_blocks(["One"])
      mine = insert(:conversation)
      theirs = insert(:conversation)

      {:ok, %{proposals: run}} = propose_body(document, mine, "## One\n\n## Two\n\n## Three")
      {:ok, %{proposals: [other]}} = propose_body(document, theirs, "## One\n\n## Elsewhere")

      assert Enum.all?(run, &(&1.after_block_id == one.block_id))
      assert other.after_block_id == one.block_id

      pairs = Enum.map(Documents.contentions(document), &Enum.sort(&1.proposal_ids))

      # Within one run the order was written down. Across two topics nothing
      # says which goes first, and inventing an order is the decision this
      # system leaves to a person.
      for [first, second] <- combinations(Enum.map(run, & &1.id)) do
        refute Enum.sort([first, second]) in pairs
      end

      for member <- run do
        assert Enum.sort([member.id, other.id]) in pairs
      end
    end
  end

  describe "commit_proposals/2" do
    test "publishes exactly what it was named, and nothing beside it" do
      %{document: document, blocks: [one, two]} = document_with_blocks(["One", "Two"])
      conversation = insert(:conversation)

      {:ok, %{proposals: [taken]}} =
        propose_block(document, one.block_id, conversation, "## One, tighter")

      {:ok, %{proposals: [left]}} =
        propose_block(document, two.block_id, conversation, "## Two, tighter")

      {:ok, %{proposals: [title]}} = propose_title(document, conversation, "A better name")

      # Ticked, and not named. A publish takes what it was given.
      {:ok, _staged} = Documents.stage_proposal(document, left.id, true)
      {:ok, _staged} = Documents.stage_proposal(document, title.id, true)

      assert {:ok, publication} = publish(document, [taken.id])
      assert publication.result == :published
      assert publication.accepted == [taken.id]
      assert Enum.map(blocks_of(publication), & &1.content) == ["## One, tighter", "## Two"]
      assert publication.revision.title == "Document"
      assert reload(left).status == :live
      assert reload(title).status == :live
    end

    test "publishing a title is naming it like anything else" do
      %{document: document} = document_with_blocks(["One"])
      conversation = insert(:conversation)

      {:ok, %{proposals: [title]}} = propose_title(document, conversation, "A better name")

      assert {:ok, publication} = publish(document, [title.id])
      assert publication.revision.title == "A better name"
      assert reload(title).status == :accepted
      assert reload(title).accepted_revision_id == publication.revision.id
    end

    test "refuses two proposals that cannot both be true" do
      %{document: document, first: first, second: second} = two_competing_proposals()

      assert {:error, :conflicting_selection, details} = publish(document, [first.id, second.id])
      assert [%{proposal_ids: ids}] = details.conflicts
      assert Enum.sort(ids) == Enum.sort([first.id, second.id])
    end

    test "supersedes what the published change beat, and only that" do
      %{document: document, blocks: [one, two]} = document_with_blocks(["One", "Two"])
      mine = insert(:conversation)
      theirs = insert(:conversation)
      elsewhere = insert(:conversation)

      {:ok, %{proposals: [update]}} = propose_block(document, one.block_id, mine, "## One, mine")

      {:ok, %{proposals: [rival]}} =
        propose_block(document, one.block_id, theirs, "## One, theirs")

      # A third topic, because re-proposing a body replaces the body work of the
      # topic that does it -- which would take the rival with it.
      {:ok, %{proposals: [move]}} = propose_body(document, elsewhere, "## Two\n\n## One")

      {:ok, %{proposals: [unrelated]}} =
        propose_block(document, two.block_id, insert(:conversation), "## Two, tighter")

      person = insert(:actor)

      {:ok, _adopted} =
        Documents.adopt_proposal(document, update.id, latest_revision_id(document), person.id)

      assert {:ok, publication} = publish(document, [update.id])
      assert publication.accepted == [update.id]
      assert publication.superseded == [rival.id]

      assert reload(rival).status == :superseded
      # A move of the paragraph whose words were just settled is still a
      # different question, and a proposal about another paragraph is still
      # true.
      assert reload(move).status == :live
      assert reload(unrelated).status == :live
    end

    test "a publish that leaves a proposal out does not beat it" do
      %{document: document, first: first, second: second} = two_competing_proposals()
      person = insert(:actor)

      {:ok, _adopted} =
        Documents.adopt_proposal(document, first.id, latest_revision_id(document), person.id)

      # Adopting is not publishing. The loser is still live afterwards.
      assert reload(second).status == :live
      assert reload(first).status == :live
    end

    test "writes no revision when everything named is already true" do
      %{document: document, blocks: [one, _two]} = document_with_blocks(["One", "Two"])
      mine = insert(:conversation)
      theirs = insert(:conversation)

      {:ok, %{proposals: [mine_update]}} =
        propose_block(document, one.block_id, mine, "## One, agreed")

      {:ok, %{proposals: [rival]}} =
        propose_block(document, one.block_id, theirs, "## One, otherwise")

      rewrite_block(document, one.block_id, "## One, agreed")
      {:ok, _staged} = force_stage(mine_update)

      before = latest_revision_id(document)
      assert {:ok, publication} = publish(document, [mine_update.id])

      assert publication.result == :already_applied
      assert is_nil(publication.revision)
      assert publication.already_applied == [mine_update.id]
      assert publication.accepted == []
      assert latest_revision_id(document) == before

      # Not accepted -- no publish applied it -- and nothing was beaten on its
      # account. What does happen is that it stops asking to be taken.
      assert reload(mine_update).status == :live
      refute reload(mine_update).staged
      assert reload(rival).status == :live
    end

    test "refuses a proposal whose target has gone" do
      %{document: document, blocks: [one, _two]} = document_with_blocks(["One", "Two"])
      conversation = insert(:conversation)

      {:ok, %{proposals: [proposal]}} =
        propose_block(document, one.block_id, conversation, "## One, tighter")

      delete_block(document, one.block_id)

      assert {:error, :proposal_not_applicable, details} = publish(document, [proposal.id])
      assert details.reason == :target_deleted
    end

    test "asks again before overwriting words that changed underneath" do
      %{document: document, blocks: [one, _two]} = document_with_blocks(["One", "Two"])
      conversation = insert(:conversation)
      person = insert(:actor)

      {:ok, %{proposals: [proposal]}} =
        propose_block(document, one.block_id, conversation, "## One, tighter")

      rewrite_block(document, one.block_id, "## One, rewritten by a person")

      assert {:error, :needs_reconfirmation, details} = publish(document, [proposal.id])
      assert details.reason == :content_diverged

      # Adopting against what the block says today is the confirmation.
      {:ok, _adopted} =
        Documents.adopt_proposal(document, proposal.id, latest_revision_id(document), person.id)

      assert {:ok, publication} = publish(document, [proposal.id])
      assert Enum.map(blocks_of(publication), & &1.content) == ["## One, tighter", "## Two"]
    end

    test "a deletion whose target was rewritten needs confirming too" do
      %{document: document, blocks: [one, _two]} = document_with_blocks(["One", "Two"])
      conversation = insert(:conversation)

      {:ok, %{proposals: [delete]}} = propose_body(document, conversation, "## Two")
      rewrite_block(document, one.block_id, "## One, and something new")

      assert {:error, :needs_reconfirmation, details} = publish(document, [delete.id])
      assert details.reason == :target_rewritten
    end

    test "a move whose destination this same publish removes is refused" do
      %{document: document, blocks: [one, two, three]} =
        document_with_blocks(["One", "Two", "Three"])

      mover = insert(:conversation)
      remover = insert(:conversation)

      {:ok, %{proposals: [move]}} =
        propose_body(document, mover, "## Two\n\n## Three\n\n## One")

      {:ok, %{proposals: [delete]}} = propose_body(document, remover, "## One\n\n## Two")

      assert move.operation == :move and move.block_id == one.block_id
      assert move.after_block_id == three.block_id
      assert delete.operation == :delete and delete.block_id == three.block_id

      assert {:error, :unresolved_dependency, details} = publish(document, [move.id, delete.id])
      assert details.proposal_ids == [move.id]
      assert two
    end

    test "a run keeps its order however it is taken apart" do
      %{document: document, blocks: [one]} = document_with_blocks(["One"])
      conversation = insert(:conversation)

      {:ok, %{proposals: proposals}} =
        propose_body(document, conversation, "## One\n\n## Two\n\n## Three\n\n## Four")

      [a, b, c] = Enum.sort_by(proposals, & &1.run_ordinal)

      {:ok, _first} = publish(document, [a.id, c.id])
      assert contents(document) == ["## One", "## Two", "## Four"]

      {:ok, _second} = publish(document, [b.id])
      assert contents(document) == ["## One", "## Two", "## Three", "## Four"]
      assert Enum.map([a, b, c], &reload(&1).status) == [:accepted, :accepted, :accepted]
      assert one
    end

    test "the same run published the other way round lands the same document" do
      %{document: document} = document_with_blocks(["One"])
      conversation = insert(:conversation)

      {:ok, %{proposals: proposals}} =
        propose_body(document, conversation, "## One\n\n## Two\n\n## Three\n\n## Four")

      [a, b, c] = Enum.sort_by(proposals, & &1.run_ordinal)

      {:ok, _first} = publish(document, [b.id])
      assert contents(document) == ["## One", "## Three"]

      {:ok, _second} = publish(document, [a.id, c.id])
      assert contents(document) == ["## One", "## Two", "## Three", "## Four"]
    end

    test "refuses an empty, duplicated or foreign selection" do
      %{document: document} = document_with_blocks(["One"])
      %{proposal: elsewhere, document: _other} = one_uncontested_proposal()
      %{proposal: proposal} = one_uncontested_proposal(document)

      assert {:error, :nothing_to_commit, _details} = publish(document, [])

      assert {:error, :duplicate_proposal, _details} =
               publish(document, [proposal.id, proposal.id])

      assert {:error, :proposal_not_found, details} = publish(document, [elsewhere.id])
      assert details.proposal_ids == [elsewhere.id]
    end

    test "refuses a proposal that is no longer live" do
      %{proposal: proposal, document: document} = one_uncontested_proposal()
      {:ok, _rejected} = Documents.reject_proposal(document, proposal.id, insert(:actor).id, nil)

      assert {:error, :proposal_not_live, details} = publish(document, [proposal.id])
      assert details.proposal_ids == [proposal.id]
    end

    test "refuses to publish against a revision that has moved" do
      %{proposal: proposal, document: document} = one_uncontested_proposal()
      stale = latest_revision_id(document)
      append_block(document, "## Elsewhere")

      assert {:error, :stale_document, _details} =
               Documents.commit_proposals(document, %{
                 actor_id: insert(:actor).id,
                 base_revision_id: stale,
                 proposal_ids: [proposal.id]
               })
    end

    test "writes nothing at all when a later step fails" do
      %{proposal: proposal, document: document} = one_uncontested_proposal()
      before = latest_revision_id(document)

      assert {:error, :annotation_not_found, _details} =
               Documents.commit_proposals(document, %{
                 actor_id: insert(:actor).id,
                 base_revision_id: before,
                 proposal_ids: [proposal.id],
                 confirm_annotation_ids: [UUIDv7.generate()]
               })

      assert latest_revision_id(document) == before
      assert reload(proposal).status == :live
    end

    test "a published block still belongs to the AI that wrote it" do
      %{proposal: proposal, document: document} = one_uncontested_proposal()

      {:ok, publication} = publish(document, [proposal.id])

      assert [%{actor_id: actor_id} | _rest] =
               Enum.filter(blocks_of(publication), &(&1.block_id == proposal.block_id))

      assert actor_id == default_assistant().id
    end
  end

  describe "commit_many/1" do
    test "writes one publication per document, all in one transaction" do
      %{proposal: first, document: one} = one_uncontested_proposal()
      %{proposal: second, document: two} = one_uncontested_proposal()
      person = insert(:actor)

      assert {:ok, [left, right]} =
               Documents.commit_many([
                 {one, publish_attrs(one, person, [first.id])},
                 {two, publish_attrs(two, person, [second.id])}
               ])

      assert left.document_id == one.id
      assert right.document_id == two.id
      assert reload(first).status == :accepted
      assert reload(second).status == :accepted
    end

    test "one entry failing rolls the whole batch back, and says which" do
      %{proposal: first, document: one} = one_uncontested_proposal()
      %{proposal: second, document: two} = one_uncontested_proposal()
      person = insert(:actor)

      assert {:error, :stale_document, details} =
               Documents.commit_many([
                 {one, publish_attrs(one, person, [first.id])},
                 {two,
                  publish_attrs(two, person, [second.id])
                  |> Map.put(:base_revision_id, UUIDv7.generate())}
               ])

      assert details.document_id == two.id
      assert reload(first).status == :live
    end
  end

  describe "review_proposals/2 and conversation_document_view/2" do
    test "compares against the current body, from one snapshot" do
      %{document: document, blocks: [one, _two]} = document_with_blocks(["One", "Two"])
      conversation = insert(:conversation)

      {:ok, %{proposals: [_proposal]}} =
        propose_block(document, one.block_id, conversation, "## One, tighter")

      assert {:ok, review} = Documents.review_proposals(document, %{})
      assert review.current_revision_id == latest_revision_id(document)
      assert [detail] = review.proposals
      assert detail.state == :applicable
      refute detail.adopted
      assert detail.conflicting_proposal_ids == []
    end

    test "reading changes nothing" do
      %{document: document, first: first} = two_competing_proposals()

      {:ok, _review} = Documents.review_proposals(document, %{})

      assert is_nil(reload(first).adopted_revision_id)
      refute reload(first).staged
    end

    test "shows a topic its own work laid over the document, and names what it cannot lay" do
      %{document: document, blocks: [one, two]} = document_with_blocks(["One", "Two"])
      mine = insert(:conversation)
      theirs = insert(:conversation)

      {:ok, %{proposals: [applied]}} =
        propose_block(document, one.block_id, mine, "## One, mine")

      {:ok, %{proposals: [blocked]}} =
        propose_block(document, two.block_id, mine, "## Two, mine")

      {:ok, %{proposals: [_other]}} =
        propose_block(document, one.block_id, theirs, "## One, theirs")

      delete_block(document, two.block_id)

      assert {:ok, view} = Documents.conversation_document_view(document, mine.id)
      assert Enum.map(view.blocks, & &1.content) == ["## One, mine"]
      assert [%{block_id: block_id, proposal_id: proposal_id, other_proposals: 1}] = view.blocks
      assert block_id == one.block_id
      assert proposal_id == applied.id

      # Its own blocked work comes back named. Dropped silently, it would be
      # written again from scratch on the next turn.
      assert [%{proposal_id: id, reason: :target_deleted}] = view.unapplicable
      assert id == blocked.id
    end
  end

  describe "who a proposal is by" do
    test "a plain chat and an actor topic sign identically" do
      %{document: document, blocks: [one, two]} = document_with_blocks(["One", "Two"])

      {:ok, %{proposals: [from_actor]}} =
        propose_block(document, one.block_id, insert(:conversation), "## One, tighter")

      {:ok, %{proposals: [from_chat]}} =
        propose_block(document, two.block_id, plain_chat(), "## Two, tighter")

      assert from_actor.actor_id == default_assistant().id
      assert from_chat.actor_id == default_assistant().id
    end

    test "a topic that does not exist is refused by name" do
      %{document: document, blocks: [one, _two]} = document_with_blocks(["One", "Two"])

      assert {:error, :conversation_not_found, _details} =
               Documents.propose_block(document, %{
                 block_id: one.block_id,
                 conversation_id: UUIDv7.generate(),
                 base_revision_id: latest_revision_id(document),
                 content: "## One, tighter"
               })
    end
  end

  # Helpers

  defp propose_body(document, conversation, markdown) do
    Documents.propose_document(document, %{
      conversation_id: conversation.id,
      content: markdown,
      base_revision_id: latest_revision_id(document)
    })
  end

  defp propose_block(document, block_id, conversation, content) do
    Documents.propose_block(document, %{
      block_id: block_id,
      conversation_id: conversation.id,
      content: content,
      base_revision_id: latest_revision_id(document)
    })
  end

  defp propose_title(document, conversation, content) do
    Documents.propose_title(document, %{
      conversation_id: conversation.id,
      content: content,
      base_revision_id: latest_revision_id(document)
    })
  end

  defp publish(document, proposal_ids, actor \\ nil) do
    Documents.commit_proposals(
      document,
      publish_attrs(document, actor || insert(:actor), proposal_ids)
    )
  end

  defp publish_attrs(document, actor, proposal_ids) do
    %{
      actor_id: actor.id,
      base_revision_id: latest_revision_id(document),
      proposal_ids: proposal_ids
    }
  end

  defp one_uncontested_proposal(document \\ nil) do
    %{document: document, blocks: blocks} =
      case document do
        nil -> document_with_blocks(["One", "Two"])
        existing -> %{document: existing, blocks: document_blocks(existing)}
      end

    [one | _rest] = blocks
    conversation = insert(:conversation)

    {:ok, %{proposals: [proposal]}} =
      propose_block(
        document,
        one.block_id,
        conversation,
        "## One, tighter #{System.unique_integer([:positive])}"
      )

    %{document: document, proposal: proposal, block_id: one.block_id}
  end

  defp two_competing_proposals do
    %{document: document, blocks: [one, _two]} = document_with_blocks(["One", "Two"])

    {:ok, %{proposals: [first]}} =
      propose_block(document, one.block_id, insert(:conversation), "## One, mine")

    {:ok, %{proposals: [second]}} =
      propose_block(document, one.block_id, insert(:conversation), "## One, theirs")

    %{document: document, first: first, second: second, block_id: one.block_id}
  end

  # The one place a tick is written without going through the check that guards
  # it: setting up a state a person could have reached before an argument
  # started.
  defp force_stage(proposal) do
    proposal |> BlockProposal.staged_changeset(true) |> Repo.update()
  end

  defp detail_for(document, proposal_id) do
    {:ok, review} = Documents.review_proposals(document, %{id: proposal_id})
    [detail] = review.proposals
    detail
  end

  defp append_block(document, content) do
    [last | _rest] = Enum.reverse(document_blocks(document))

    {:ok, revision} =
      Documents.create_revision(document, %{
        base_revision_id: latest_revision_id(document),
        block_ops: [
          %{
            op: :insert_after,
            after_block_id: last.block_id,
            actor_id: insert(:actor).id,
            content: content
          }
        ]
      })

    revision
  end

  defp rewrite_block(document, block_id, content) do
    {:ok, revision} =
      Documents.create_revision(document, %{
        base_revision_id: latest_revision_id(document),
        block_ops: [
          %{op: :update, block_id: block_id, actor_id: insert(:actor).id, content: content}
        ]
      })

    revision
  end

  defp delete_block(document, block_id) do
    {:ok, revision} =
      Documents.create_revision(document, %{
        base_revision_id: latest_revision_id(document),
        block_ops: [%{op: :delete, block_id: block_id}]
      })

    revision
  end

  defp blocks_of(%{revision: revision}), do: blocks_of(revision)
  defp blocks_of(revision), do: Enum.sort_by(revision.blocks, & &1.position)

  defp contents(document), do: Enum.map(document_blocks(document), & &1.content)

  defp reload(%BlockProposal{id: id}), do: Repo.get!(BlockProposal, id)

  defp combinations(ids) do
    for left <- ids, right <- ids, left < right, do: [left, right]
  end

  defp document_blocks(document) do
    Documents.get_document!(document.id).latest_revision.blocks
    |> Enum.sort_by(& &1.position)
  end

  # No actor: a proposal is attributed to the stand-in AI, and a caller able to
  # name an author could name the wrong one.
  defp plain_chat do
    insert(:conversation,
      mode: :chat,
      assistant_actor: nil,
      provider: "openai",
      model: "gpt-5.4",
      thinking_level: "medium"
    )
  end

  # One block per heading: the body is cut server-side, so a test wanting N
  # blocks has to write a body that cuts into N.
  defp document_with_blocks(contents) do
    actor = insert(:actor)

    {:ok, document} =
      Documents.create_document(%{
        title: "Document",
        actor_id: actor.id,
        markdown: Enum.map_join(contents, "\n\n", &"## #{&1}")
      })

    %{document: document, blocks: Enum.sort_by(document.latest_revision.blocks, & &1.position)}
  end

  defp latest_revision_id(document) do
    Documents.get_document!(document.id).latest_revision.id
  end
end
