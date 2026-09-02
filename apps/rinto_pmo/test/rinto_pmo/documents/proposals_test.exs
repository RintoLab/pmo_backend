defmodule RintoPMO.Documents.ProposalsTest do
  use RintoPMO.DataCase, async: true

  alias RintoPMO.Actors
  alias RintoPMO.ActorsMock
  alias RintoPMO.Annotations
  alias RintoPMO.AnnotationsMock
  alias RintoPMO.Conversations
  alias RintoPMO.ConversationsMock
  alias RintoPMO.Documents
  alias RintoPMO.Documents.BlockOps
  alias RintoPMO.Documents.BlockProposal
  alias RintoPMO.Projects
  alias RintoPMO.ProjectsMock
  alias RintoPMO.Setup

  setup do
    # Commit resolves annotations through the injected context; these tests are
    # about what actually lands in the database, so it runs for real.
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

  describe "propose_block/2" do
    test "records a topic's proposal and reports it stands alone" do
      %{document: document, blocks: [block | _rest]} = document_with_blocks(["One", "Two"])
      conversation = insert(:conversation)

      assert {:ok, %{proposal: %BlockProposal{} = proposal, live_proposals: 1}} =
               propose(document, block.block_id, conversation, "Tighter one")

      assert proposal.status == :live
      assert proposal.block_id == block.block_id
      assert proposal.conversation_id == conversation.id
      assert proposal.content == "Tighter one"
      assert proposal.base_revision_id == latest_revision_id(document)

      # Proposing is how an AI writes, so the author is the assistant this topic
      # is talking to -- derived here, never supplied.
      assert proposal.actor_id == conversation.assistant_actor_id
    end

    test "a topic revising the same block keeps exactly one live proposal" do
      %{document: document, blocks: [block | _rest]} = document_with_blocks(["One"])
      conversation = insert(:conversation)

      ids =
        for round <- 1..5 do
          assert {:ok, %{proposal: proposal, live_proposals: 1}} =
                   propose(document, block.block_id, conversation, "Attempt #{round}")

          proposal.id
        end

      # The same intent iterating: one row, rewritten in place.
      assert Enum.uniq(ids) |> length() == 1

      assert [only] = Documents.list_proposals(document, %{status: :live})
      assert only.content == "Attempt 5"
      assert Documents.contentions(document) == []
    end

    test "two topics on one block make a contention, both still live" do
      %{document: document, blocks: [block | _rest]} = document_with_blocks(["One"])
      first = insert(:conversation)
      second = insert(:conversation)

      assert {:ok, %{live_proposals: 1}} =
               propose(document, block.block_id, first, "Version A")

      assert {:ok, %{live_proposals: 2}} =
               propose(document, block.block_id, second, "Version B")

      assert [%{block_id: block_id, proposals: proposals}] = Documents.contentions(document)
      assert block_id == block.block_id
      assert Enum.map(proposals, & &1.status) == [:live, :live]
      assert Enum.map(proposals, & &1.content) |> Enum.sort() == ["Version A", "Version B"]
    end

    test "different blocks do not contend" do
      %{document: document, blocks: [first_block, second_block]} =
        document_with_blocks(["One", "Two"])

      {:ok, _} = propose(document, first_block.block_id, insert(:conversation), "A")
      {:ok, _} = propose(document, second_block.block_id, insert(:conversation), "B")

      assert Documents.contentions(document) == []
    end

    test "refuses a block the document does not have" do
      %{document: document} = document_with_blocks(["One"])
      stray = UUIDv7.generate()

      assert {:error, :unknown_block, %{block_id: ^stray}} =
               propose(document, stray, insert(:conversation), "Nowhere")
    end

    test "requires a topic, an actor and content" do
      %{document: document, blocks: [block | _rest]} = document_with_blocks(["One"])

      assert {:error, changeset} =
               Documents.propose_block(document, %{block_id: block.block_id})

      assert "can't be blank" in errors_on(changeset).conversation_id
      assert "can't be blank" in errors_on(changeset).actor_id
      assert "can't be blank" in errors_on(changeset).content
    end
  end

  describe "blocks_for_conversation/2" do
    test "shows a topic its own proposals and only the count of others" do
      %{document: document, blocks: [first_block, second_block]} =
        document_with_blocks(["Original one", "Original two"])

      mine = insert(:conversation)
      theirs = insert(:conversation)

      {:ok, _} = propose(document, first_block.block_id, mine, "My version")
      {:ok, _} = propose(document, first_block.block_id, theirs, "Their version")

      assert [first, second] = Documents.blocks_for_conversation(document, mine.id)

      assert first.block_id == first_block.block_id
      assert first.content == "My version"
      assert first.proposed?
      # The other text is withheld on purpose: reconciling is the human's
      # decision, and knowing someone else is here is enough to stop piling on.
      assert first.other_proposals == 1
      refute Map.has_key?(first, :other_contents)

      assert second.block_id == second_block.block_id
      assert second.content == "## Original two"
      refute second.proposed?
      assert second.other_proposals == 0
    end

    test "an uninvolved topic sees the base text and the count" do
      %{document: document, blocks: [block | _rest]} = document_with_blocks(["Original"])
      theirs = insert(:conversation)
      bystander = insert(:conversation)

      {:ok, _} = propose(document, block.block_id, theirs, "Their version")

      assert [only] = Documents.blocks_for_conversation(document, bystander.id)
      assert only.content == "## Original"
      refute only.proposed?
      assert only.other_proposals == 1
    end
  end

  describe "conversation_working_set/1" do
    test "groups a topic's standing work by the document it is against" do
      %{document: first, blocks: [first_block | _rest]} = document_with_blocks(["One", "Two"])
      %{document: second, blocks: [second_block | _rest]} = document_with_blocks(["Elsewhere"])
      conversation = insert(:conversation)

      {:ok, _} = propose(first, first_block.block_id, conversation, "Tighter")
      {:ok, _} = propose(second, second_block.block_id, conversation, "Follows from the above")

      assert [one, two] = Documents.conversation_working_set(conversation.id)

      # The order the topic reached each document, which is the order somebody
      # reviewing the discussion read it happen.
      assert one.document.id == first.id
      assert two.document.id == second.id

      # The title comes with it: a review screen cannot ask somebody to approve
      # a change to an id.
      assert one.document.latest_revision.title == "Document"
      assert [%{proposal: proposal, contended: false}] = two.proposals
      assert proposal.content == "Follows from the above"
    end

    test "marks the slots somebody else is also proposing into" do
      %{document: document, blocks: [contested, mine]} = document_with_blocks(["One", "Two"])
      conversation = insert(:conversation)
      theirs = insert(:conversation)

      {:ok, _} = propose(document, contested.block_id, conversation, "My version")
      {:ok, _} = propose(document, contested.block_id, theirs, "Their version")
      {:ok, _} = propose(document, mine.block_id, conversation, "Uncontested")

      assert [%{proposals: proposals}] = Documents.conversation_working_set(conversation.id)

      assert [
               %{proposal: %{block_id: first_block}, contended: true},
               %{proposal: %{block_id: second_block}, contended: false}
             ] = proposals

      assert first_block == contested.block_id
      assert second_block == mine.block_id
    end

    # A whole-document proposal has no block to contend over, so the slot is
    # the document and the scope. Two of them are a contention; a document
    # proposal and a title proposal are not.
    test "a document-wide proposal contends only with another of its own scope" do
      %{document: document} = document_with_blocks(["One"])
      conversation = insert(:conversation)
      theirs = insert(:conversation)

      {:ok, _} =
        Documents.propose_document(document, %{
          conversation_id: conversation.id,
          content: "## Rewritten"
        })

      {:ok, _} =
        Documents.propose_title(document, %{
          conversation_id: theirs.id,
          content: "A different name"
        })

      assert [%{proposals: [%{contended: false}]}] =
               Documents.conversation_working_set(conversation.id)

      {:ok, _} =
        Documents.propose_document(document, %{
          conversation_id: theirs.id,
          content: "## Rewritten differently"
        })

      assert [%{proposals: [%{contended: true}]}] =
               Documents.conversation_working_set(conversation.id)
    end

    # Not the same answer as a topic that does not exist, which is why the
    # endpoint above this fetches the conversation first.
    test "a topic with nothing standing has an empty working set" do
      assert [] == Documents.conversation_working_set(insert(:conversation).id)
    end

    # A rejected proposal is the record of why something was not chosen. It is
    # worth keeping and it is not waiting to be committed.
    test "leaves out what has already been decided" do
      %{document: document, blocks: [block | _rest]} = document_with_blocks(["One"])
      conversation = insert(:conversation)
      theirs = insert(:conversation)

      {:ok, %{proposal: mine}} = propose(document, block.block_id, conversation, "My version")
      {:ok, %{proposal: winner}} = propose(document, block.block_id, theirs, "Their version")

      {:ok, _decided} =
        Documents.decide_block(document, block.block_id, winner.id, insert(:actor).id)

      assert Repo.get!(BlockProposal, mine.id).status == :rejected
      assert [] == Documents.conversation_working_set(conversation.id)
      assert [%{proposals: [%{contended: false}]}] = Documents.conversation_working_set(theirs.id)
    end
  end

  describe "commit_many/1" do
    test "writes one revision per document, all in one transaction" do
      %{document: first, blocks: [first_block | _rest]} = document_with_blocks(["One"])
      %{document: second, blocks: [second_block | _rest]} = document_with_blocks(["Two"])
      conversation = insert(:conversation)
      committer = insert(:actor)

      {:ok, _} = propose(first, first_block.block_id, conversation, "Rewritten one")
      {:ok, _} = propose(second, second_block.block_id, conversation, "Rewritten two")

      assert {:ok, [one, two]} =
               Documents.commit_many([
                 {first, commit_attrs(first, committer, conversation)},
                 {second, commit_attrs(second, committer, conversation)}
               ])

      # In the order they were asked for, which is the order the screen was in.
      # Documents are locked in id order, and that is nobody else's business.
      assert one.document_id == first.id
      assert two.document_id == second.id

      # One revision each, each naming the discussion that produced it. There
      # is no batch record and nothing new was stored.
      assert one.source_conversation_id == conversation.id
      assert two.source_conversation_id == conversation.id

      assert Enum.map(Documents.get_revision!(first, one.id).blocks, & &1.content) ==
               ["Rewritten one"]

      assert Enum.map(Documents.get_revision!(second, two.id).blocks, & &1.content) ==
               ["Rewritten two"]
    end

    # Half of a cross-document change landing is the worst outcome available:
    # the documents then disagree and nothing says which half is the answer.
    test "one document failing leaves none of them written" do
      %{document: first, blocks: [first_block | _rest]} = document_with_blocks(["One"])
      %{document: second, blocks: [contended | _rest]} = document_with_blocks(["Two"])
      conversation = insert(:conversation)
      theirs = insert(:conversation)
      committer = insert(:actor)

      {:ok, _} = propose(first, first_block.block_id, conversation, "Rewritten one")
      {:ok, _} = propose(second, contended.block_id, conversation, "My version")
      {:ok, _} = propose(second, contended.block_id, theirs, "Their version")

      before_first = latest_revision_id(first)
      before_second = latest_revision_id(second)

      assert {:error, :unresolved_contention, details} =
               Documents.commit_many([
                 {first, commit_attrs(first, committer, conversation)},
                 {second,
                  second
                  |> commit_attrs(committer, conversation)
                  |> Map.put(:block_ids, [contended.block_id])}
               ])

      # Which document it happened in: one entry in a batch of four is not
      # findable from a message about a contention.
      assert details.document_id == second.id

      assert latest_revision_id(first) == before_first
      assert latest_revision_id(second) == before_second
    end

    test "refuses the same document twice" do
      %{document: document} = document_with_blocks(["One"])
      committer = insert(:actor)
      attrs = commit_attrs(document, committer, insert(:conversation))

      assert {:error, :duplicate_document, %{document_id: document_id}} =
               Documents.commit_many([{document, attrs}, {document, attrs}])

      assert document_id == document.id
    end

    test "confirms each document's own annotations against its own revision" do
      %{document: first, blocks: [first_block | _rest]} = document_with_blocks(["One"])
      %{document: second, blocks: [second_block | _rest]} = document_with_blocks(["Two"])
      conversation = insert(:conversation)
      committer = insert(:actor)
      note = insert(:annotation, document: second)

      {:ok, _} = propose(first, first_block.block_id, conversation, "Rewritten one")
      {:ok, _} = propose(second, second_block.block_id, conversation, "Rewritten two")

      assert {:ok, [_one, two]} =
               Documents.commit_many([
                 {first, commit_attrs(first, committer, conversation)},
                 {second,
                  first
                  |> commit_attrs(committer, conversation)
                  |> Map.merge(%{
                    base_revision_id: latest_revision_id(second),
                    confirm_annotation_ids: [note.id]
                  })}
               ])

      note = Repo.get!(RintoPMO.Annotations.Annotation, note.id)
      assert note.confirmed_by_revision_id == two.id
    end
  end

  describe "decide_block/4" do
    test "rejects every proposal but one, leaving the winner pending" do
      %{document: document, blocks: [block | _rest]} = document_with_blocks(["One"])
      actor = insert(:actor)

      {:ok, %{proposal: keeper}} =
        propose(document, block.block_id, insert(:conversation), "Version A")

      {:ok, %{proposal: loser}} =
        propose(document, block.block_id, insert(:conversation), "Version B")

      assert {:ok, adopted} =
               Documents.decide_block(document, block.block_id, keeper.id, actor.id)

      assert adopted.id == keeper.id

      # Deciding a contention is not committing it: the winner is merely no
      # longer contended and still has to be committed like anything else.
      assert adopted.status == :live
      assert adopted.decided_by_actor_id == nil

      # "Why A and not B" is the record this system exists to keep, so the
      # loser moves status rather than disappearing.
      loser = Repo.get!(BlockProposal, loser.id)
      assert loser.status == :rejected
      assert loser.decided_by_actor_id == actor.id
      assert loser.decided_at

      assert Documents.contentions(document) == []
    end

    test "refuses a proposal that is not live on that block" do
      %{document: document, blocks: [block | _rest]} = document_with_blocks(["One"])
      stray = UUIDv7.generate()

      assert {:error, :proposal_not_found, %{proposal_id: ^stray}} =
               Documents.decide_block(document, block.block_id, stray, insert(:actor).id)
    end
  end

  describe "commit_proposals/2" do
    test "writes a revision from the live proposals and accepts them" do
      %{document: document, blocks: [first_block, second_block]} =
        document_with_blocks(["Original one", "Original two"])

      conversation = insert(:conversation)
      committer = insert(:actor)

      {:ok, %{proposal: proposal}} =
        propose(document, first_block.block_id, conversation, "Rewritten one")

      assert {:ok, revision} =
               Documents.commit_proposals(document, %{
                 actor_id: committer.id,
                 base_revision_id: latest_revision_id(document),
                 source_conversation_id: conversation.id,
                 change_summary: "Tightened the opening"
               })

      assert revision.change_summary == "Tightened the opening"
      assert revision.source_conversation_id == conversation.id

      blocks = Documents.get_revision!(document, revision.id).blocks
      assert Enum.map(blocks, & &1.content) == ["Rewritten one", "## Original two"]
      # Block identity survives the rewrite; only the snapshot is new.
      assert Enum.map(blocks, & &1.block_id) == [first_block.block_id, second_block.block_id]
      # The block is attributed to whoever wrote the text -- the topic's assistant
      # -- and not to whoever approved it.
      assert Enum.map(blocks, & &1.actor_id) ==
               [conversation.assistant_actor_id, second_block.actor_id]

      refute committer.id in Enum.map(blocks, & &1.actor_id)

      accepted = Repo.get!(BlockProposal, proposal.id)
      assert accepted.status == :accepted
      assert accepted.decided_by_actor_id == committer.id
    end

    test "resolves the named annotations against the new revision" do
      %{document: document, blocks: [block | _rest]} = document_with_blocks(["Original"])
      settled = insert(:annotation, document: document)
      untouched = insert(:annotation, document: document)

      {:ok, _} = propose(document, block.block_id, insert(:conversation), "New")

      assert {:ok, revision} =
               Documents.commit_proposals(document, %{
                 actor_id: insert(:actor).id,
                 base_revision_id: latest_revision_id(document),
                 confirm_annotation_ids: [settled.id]
               })

      settled = Repo.get!(RintoPMO.Annotations.Annotation, settled.id)
      assert settled.confirmed_at
      assert settled.confirmed_by_revision_id == revision.id

      # One commit may touch three annotations and settle two; confirming is
      # named per annotation, never inferred from what the revision changed.
      assert Repo.get!(RintoPMO.Annotations.Annotation, untouched.id).confirmed_at == nil
    end

    test "refuses a contended block but not the blocks beside it" do
      %{document: document, blocks: [contended_block, quiet_block]} =
        document_with_blocks(["Contended", "Quiet"])

      actor = insert(:actor)
      first = insert(:conversation)
      second = insert(:conversation)

      {:ok, _} = propose(document, contended_block.block_id, first, "Version A")
      {:ok, _} = propose(document, contended_block.block_id, second, "Version B")
      {:ok, _} = propose(document, quiet_block.block_id, first, "Uncontested")

      contended_id = contended_block.block_id

      assert {:error, :unresolved_contention, %{block_ids: [^contended_id]}} =
               Documents.commit_proposals(document, %{
                 actor_id: actor.id,
                 base_revision_id: latest_revision_id(document),
                 block_ids: [contended_block.block_id, quiet_block.block_id]
               })

      # Selecting per block is what keeps one argument from holding up the
      # rest of the document.
      assert {:ok, revision} =
               Documents.commit_proposals(document, %{
                 actor_id: actor.id,
                 base_revision_id: latest_revision_id(document),
                 block_ids: [quiet_block.block_id]
               })

      blocks = Documents.get_revision!(document, revision.id).blocks
      assert Enum.map(blocks, & &1.content) == ["## Contended", "Uncontested"]
    end

    test "the default selection skips contended blocks" do
      %{document: document, blocks: [contended_block, quiet_block]} =
        document_with_blocks(["Contended", "Quiet"])

      actor = insert(:actor)
      first = insert(:conversation)
      second = insert(:conversation)

      {:ok, _} = propose(document, contended_block.block_id, first, "Version A")
      {:ok, _} = propose(document, contended_block.block_id, second, "Version B")
      {:ok, _} = propose(document, quiet_block.block_id, first, "Uncontested")

      assert {:ok, revision} =
               Documents.commit_proposals(document, %{
                 actor_id: actor.id,
                 base_revision_id: latest_revision_id(document)
               })

      blocks = Documents.get_revision!(document, revision.id).blocks
      assert Enum.map(blocks, & &1.content) == ["## Contended", "Uncontested"]

      # The argument is still there, waiting to be settled.
      assert [%{block_id: still_contended}] = Documents.contentions(document)
      assert still_contended == contended_block.block_id
    end

    test "commits a contended block once it has been decided" do
      %{document: document, blocks: [block | _rest]} = document_with_blocks(["Original"])
      actor = insert(:actor)

      {:ok, %{proposal: keeper}} =
        propose(document, block.block_id, insert(:conversation), "Version A")

      {:ok, _} = propose(document, block.block_id, insert(:conversation), "Version B")

      {:ok, _adopted} = Documents.decide_block(document, block.block_id, keeper.id, actor.id)

      assert {:ok, revision} =
               Documents.commit_proposals(document, %{
                 actor_id: actor.id,
                 base_revision_id: latest_revision_id(document)
               })

      assert [%{content: "Version A"}] = Documents.get_revision!(document, revision.id).blocks
    end

    test "refuses to commit against a stale revision" do
      %{document: document, blocks: [block | _rest]} = document_with_blocks(["Original"])
      actor = insert(:actor)
      stale = latest_revision_id(document)

      {:ok, _} = propose(document, block.block_id, insert(:conversation), "First")

      {:ok, _committed} =
        Documents.commit_proposals(document, %{actor_id: actor.id, base_revision_id: stale})

      {:ok, _} = propose(document, block.block_id, insert(:conversation), "Second")

      assert {:error, :stale_document, %{current_revision_id: current}} =
               Documents.commit_proposals(document, %{
                 actor_id: actor.id,
                 base_revision_id: stale
               })

      assert current == latest_revision_id(document)
    end

    test "refuses a commit with nothing to commit" do
      %{document: document} = document_with_blocks(["Original"])

      assert {:error, :nothing_to_commit, %{}} =
               Documents.commit_proposals(document, %{
                 actor_id: insert(:actor).id,
                 base_revision_id: latest_revision_id(document)
               })
    end

    test "writes nothing at all when resolving an annotation fails" do
      %{document: document, blocks: [block | _rest]} = document_with_blocks(["Original"])
      other_document = insert(:document)
      foreign = insert(:annotation, document: other_document)
      actor = insert(:actor)

      {:ok, %{proposal: proposal}} =
        propose(document, block.block_id, insert(:conversation), "New text")

      revisions_before = length(Documents.list_revisions(document))

      assert {:error, :annotation_not_found, %{annotation_id: _id}} =
               Documents.commit_proposals(document, %{
                 actor_id: actor.id,
                 base_revision_id: latest_revision_id(document),
                 confirm_annotation_ids: [foreign.id]
               })

      # All three moves are one transaction: a revision that settled nothing,
      # or a proposal marked accepted by a commit that never landed, would each
      # leave the record lying.
      assert length(Documents.list_revisions(document)) == revisions_before
      assert Repo.get!(BlockProposal, proposal.id).status == :live
      assert Repo.get!(RintoPMO.Annotations.Annotation, foreign.id).confirmed_at == nil
    end

    test "a rejected proposal is not committed" do
      %{document: document, blocks: [block | _rest]} = document_with_blocks(["Original"])
      actor = insert(:actor)

      {:ok, %{proposal: keeper}} =
        propose(document, block.block_id, insert(:conversation), "Kept")

      {:ok, %{proposal: loser}} =
        propose(document, block.block_id, insert(:conversation), "Dropped")

      {:ok, _} = Documents.decide_block(document, block.block_id, keeper.id, actor.id)

      {:ok, revision} =
        Documents.commit_proposals(document, %{
          actor_id: actor.id,
          base_revision_id: latest_revision_id(document)
        })

      assert [%{content: "Kept"}] = Documents.get_revision!(document, revision.id).blocks
      assert Repo.get!(BlockProposal, loser.id).status == :rejected
    end
  end

  # Scope is the schema-level half of document-scope proposals: the rows and the
  # rules that keep them apart from block proposals. What builds one, and what
  # committing one does, comes later.
  describe "proposal scope" do
    test "a block proposal defaults to the block scope" do
      %{document: document, blocks: [block | _rest]} = document_with_blocks(["One"])
      conversation = insert(:conversation)

      assert {:ok, %{proposal: proposal}} =
               propose(document, block.block_id, conversation, "Tighter")

      assert proposal.scope == :block
    end

    test "a block proposal must name a block" do
      assert {:error, changeset} = insert_proposal(scope: :block, block_id: nil)
      assert "can't be blank" in errors_on(changeset).block_id
    end

    for scope <- [:document, :title] do
      test "a #{scope} proposal must not name a block" do
        assert {:error, changeset} =
                 insert_proposal(scope: unquote(scope), block_id: UUIDv7.generate())

        assert changeset |> errors_on() |> Map.fetch!(:block_id) |> List.first() =~ "not allowed"
      end
    end

    # The block index cannot reach these rows: Postgres holds NULLs distinct, so
    # every null `block_id` would look unique to it.
    test "one live proposal per topic per document-level scope" do
      %{document: document} = document_with_blocks(["One"])
      conversation = insert(:conversation)
      revision_id = latest_revision_id(document)

      attrs = [
        document_id: document.id,
        conversation_id: conversation.id,
        base_revision_id: revision_id,
        scope: :document,
        block_id: nil
      ]

      assert {:ok, _first} = insert_proposal(attrs)
      assert {:error, changeset} = insert_proposal(attrs)
      refute changeset.valid?
    end

    # Different things, so neither is an alternative to the other and one topic
    # may hold both at once. That is why `scope` is in the index.
    test "a topic may hold a live document proposal and a live title proposal" do
      %{document: document} = document_with_blocks(["One"])
      conversation = insert(:conversation)
      revision_id = latest_revision_id(document)

      attrs = [
        document_id: document.id,
        conversation_id: conversation.id,
        base_revision_id: revision_id,
        block_id: nil
      ]

      assert {:ok, _document_scope} = insert_proposal([scope: :document] ++ attrs)
      assert {:ok, _title_scope} = insert_proposal([scope: :title] ++ attrs)
    end

    # A document-level proposal groups under a `nil` block, so an unscoped query
    # would hand `nil` downstream as though it were a block to commit.
    test "document-level proposals stay out of the block-level views" do
      %{document: document, blocks: [block | _rest]} = document_with_blocks(["One", "Two"])
      conversation = insert(:conversation)
      actor = insert(:actor)

      assert {:ok, _proposed} = propose(document, block.block_id, conversation, "Tighter")

      assert {:ok, _document_scope} =
               insert_proposal(
                 document_id: document.id,
                 conversation_id: conversation.id,
                 base_revision_id: latest_revision_id(document),
                 scope: :document,
                 block_id: nil
               )

      # Neither the contention view nor a topic's working copy sees it.
      assert Documents.contentions(document) == []

      blocks = Documents.blocks_for_conversation(document, conversation.id)
      assert Enum.map(blocks, & &1.block_id) == Enum.map(document_blocks(document), & &1.block_id)

      # And a commit still finds exactly the one block proposal.
      assert {:ok, revision} =
               Documents.commit_proposals(document, %{
                 actor_id: actor.id,
                 base_revision_id: latest_revision_id(document)
               })

      assert Enum.map(revision.blocks, & &1.content) == ["Tighter", "## Two"]
    end
  end

  # Proposing is how an AI writes; a person writes by creating a revision. So the
  # author is the assistant the topic is talking to, and a caller cannot say
  # otherwise -- one that could would eventually say the wrong thing, and
  # attributing a model's work to a person erases the distinction the review flow
  # rests on.
  describe "who a proposal is by" do
    test "ignores an actor a caller tries to supply" do
      %{document: document, blocks: [block | _rest]} = document_with_blocks(["One"])
      conversation = insert(:conversation)
      impostor = insert(:actor)

      assert {:ok, %{proposal: proposal}} =
               Documents.propose_block(document, %{
                 block_id: block.block_id,
                 conversation_id: conversation.id,
                 actor_id: impostor.id,
                 content: "Tighter"
               })

      assert proposal.actor_id == conversation.assistant_actor_id
      refute proposal.actor_id == impostor.id
    end

    for scope <- [:title, :document] do
      test "the #{scope} scope is attributed the same way" do
        %{document: document} = document_with_blocks(["One"])
        conversation = insert(:conversation)

        assert {:ok, %{proposal: proposal}} =
                 propose_scope(unquote(scope), document, conversation, "## Rewritten")

        assert proposal.actor_id == conversation.assistant_actor_id
      end
    end

    test "refuses a topic with no assistant, having nobody to attribute it to" do
      %{document: document, blocks: [block | _rest]} = document_with_blocks(["One"])
      conversation = insert(:conversation, assistant_actor: nil)

      assert {:error, :assistant_actor_required, details} =
               propose(document, block.block_id, conversation, "Tighter")

      assert details.conversation_id == conversation.id
    end

    # A plain chat is talking to a model rather than to a persona, so there is
    # no assistant to credit and the default actor is the name it writes under.
    test "signs a plain chat's proposal with the default actor" do
      %{document: document, blocks: [block | _rest]} = document_with_blocks(["One"])
      signatory = default_assistant()
      conversation = plain_chat()

      assert {:ok, %{proposal: proposal}} =
               propose(document, block.block_id, conversation, "Tighter")

      assert proposal.actor_id == signatory.id
    end

    for scope <- [:title, :document] do
      test "a plain chat's #{scope} scope is signed the same way" do
        %{document: document} = document_with_blocks(["One"])
        signatory = default_assistant()

        assert {:ok, %{proposal: proposal}} =
                 propose_scope(unquote(scope), document, plain_chat(), "## Rewritten")

        assert proposal.actor_id == signatory.id
      end
    end

    # No default actor is refused rather than falling back to the person who
    # owns the topic: crediting a model's work to them is the one mistake this
    # derivation exists to prevent.
    test "refuses a plain chat when setup never made the default actor" do
      %{document: document, blocks: [block | _rest]} = document_with_blocks(["One"])
      conversation = plain_chat()

      assert {:error, :default_assistant_missing, details} =
               propose(document, block.block_id, conversation, "Tighter")

      assert details.conversation_id == conversation.id
    end

    # The default actor stands in for an absent assistant; it does not replace
    # one that is there.
    test "leaves an actor topic signed by its own assistant" do
      %{document: document, blocks: [block | _rest]} = document_with_blocks(["One"])
      signatory = default_assistant()
      conversation = insert(:conversation)

      assert {:ok, %{proposal: proposal}} =
               propose(document, block.block_id, conversation, "Tighter")

      assert proposal.actor_id == conversation.assistant_actor_id
      refute proposal.actor_id == signatory.id
    end

    test "refuses a topic that does not exist" do
      %{document: document, blocks: [block | _rest]} = document_with_blocks(["One"])
      stray = UUIDv7.generate()

      assert {:error, :conversation_not_found, %{conversation_id: ^stray}} =
               Documents.propose_block(document, %{
                 block_id: block.block_id,
                 conversation_id: stray,
                 content: "Nowhere"
               })
    end

    # A merge is not somebody writing again, so it keeps the original proposer
    # even if the topic is talking to a different assistant by then.
    test "a rebase keeps the original proposer" do
      %{document: document, blocks: [first, _second]} = document_with_blocks(["One", "Two"])
      conversation = insert(:conversation)

      assert {:ok, %{proposal: proposal}} =
               propose_document(document, conversation, "## One\n\n## Two, mine")

      original = proposal.actor_id

      assert {:ok, _proposed} =
               propose(document, first.block_id, insert(:conversation), "## One, theirs")

      assert {:ok, _landed} = commit(document, insert(:actor))

      # The topic switches to a different assistant in the meantime.
      {:ok, _conversation} =
        Conversations.update_conversation(conversation, %{
          assistant_actor_id: insert(:actor, kind: :ai).id
        })

      assert {:ok, rebased} = Documents.rebase_document_proposal(document, proposal.id)
      assert rebased.actor_id == original
    end
  end

  defp propose_scope(:title, document, conversation, _markdown) do
    propose_title(document, conversation, "Renamed")
  end

  defp propose_scope(:document, document, conversation, markdown) do
    propose_document(document, conversation, markdown)
  end

  describe "propose_title/2" do
    test "records what a topic wants the document called" do
      %{document: document} = document_with_blocks(["One"])
      conversation = insert(:conversation)

      assert {:ok, %{proposal: proposal, live_proposals: 1}} =
               propose_title(document, conversation, "标题去重验证")

      assert proposal.scope == :title
      assert proposal.block_id == nil
      assert proposal.content == "标题去重验证"
      assert proposal.status == :live
      assert proposal.base_revision_id == latest_revision_id(document)
    end

    test "a topic rewriting its title iterates on one row" do
      %{document: document} = document_with_blocks(["One"])
      conversation = insert(:conversation)

      assert {:ok, %{proposal: first}} = propose_title(document, conversation, "First try")

      assert {:ok, %{proposal: second, live_proposals: 1}} =
               propose_title(document, conversation, "Second try")

      assert second.id == first.id
      assert second.content == "Second try"
    end

    test "two topics wanting different titles is a contention" do
      %{document: document} = document_with_blocks(["One"])

      assert {:ok, %{live_proposals: 1}} =
               propose_title(document, insert(:conversation), "Mine")

      assert {:ok, %{live_proposals: 2}} =
               propose_title(document, insert(:conversation), "No, mine")
    end
  end

  describe "propose_document/2" do
    test "compiles the body into the operations that would produce it" do
      %{document: document, blocks: [first, second]} = document_with_blocks(["One", "Two"])
      conversation = insert(:conversation)

      assert {:ok, %{proposal: proposal, live_proposals: 1}} =
               propose_document(document, conversation, "## One\n\n## Two, tighter")

      assert proposal.scope == :document
      assert proposal.block_id == nil
      assert proposal.content == "## One\n\n## Two, tighter"
      assert proposal.base_revision_id == latest_revision_id(document)

      # The untouched block is absent from the operations entirely; the edited
      # one keeps its id.
      assert [%{"op" => "update", "block_id" => block_id, "content" => "## Two, tighter"}] =
               proposal.block_ops

      assert block_id == second.block_id
      refute block_id == first.block_id
    end

    # The thing a block proposal could never say.
    test "expresses a split, which no block proposal can" do
      %{document: document} = document_with_blocks(["One"])

      assert {:ok, %{proposal: proposal}} =
               propose_document(document, insert(:conversation), "## One\n\n## Two")

      assert [%{"op" => "insert_after"}] = proposal.block_ops
    end

    # Everything downstream reads these back out of jsonb, so the shape that
    # survives the round trip is the shape that matters -- string keys and string
    # op names, which BlockOps accepts alongside atoms.
    test "the stored operations still apply after a round trip through the database" do
      %{document: document} = document_with_blocks(["One", "Two", "Three"])

      assert {:ok, %{proposal: proposal}} =
               propose_document(
                 document,
                 insert(:conversation),
                 "## Zero\n\n## One\n\n## Two, tighter"
               )

      stored = Repo.reload!(proposal)
      blocks = document_blocks(document)

      assert {:ok, entries} = BlockOps.apply(blocks, stored.block_ops)

      assert Enum.map(entries, & &1.content) == ["## Zero", "## One", "## Two, tighter"]
    end

    test "a topic revising its rewrite recompiles against what is current now" do
      %{document: document, blocks: [block | _rest]} = document_with_blocks(["One", "Two"])
      conversation = insert(:conversation)
      actor = insert(:actor)

      assert {:ok, %{proposal: first}} =
               propose_document(document, conversation, "## One, tighter\n\n## Two")

      # Something else lands underneath it.
      assert {:ok, _proposed} =
               propose(document, block.block_id, insert(:conversation), "## One, theirs")

      assert {:ok, revision} = commit(document, actor)

      assert {:ok, %{proposal: second, live_proposals: 1}} =
               propose_document(
                 document,
                 conversation,
                 "## One, theirs\n\n## Two, tighter"
               )

      # One row, iterating -- and now based on the revision that just landed.
      assert second.id == first.id
      assert second.base_revision_id == revision.id
      assert [%{"content" => "## Two, tighter"}] = second.block_ops
    end

    test "refuses a body that changes nothing" do
      %{document: document} = document_with_blocks(["One", "Two"])

      assert {:error, :no_change_proposed, _details} =
               propose_document(document, insert(:conversation), "## One\n\n## Two")
    end

    # A body that is not a string at all -- the same thing `create_document/1`
    # refuses. Anything that is a string, MDEx parses.
    test "refuses a body that is not Markdown at all" do
      %{document: document} = document_with_blocks(["One"])

      assert {:error, :invalid_markdown, _details} =
               propose_document(document, insert(:conversation), %{"nope" => true})
    end

    test "two topics rewriting one document is a contention" do
      %{document: document} = document_with_blocks(["One"])

      assert {:ok, %{live_proposals: 1}} =
               propose_document(document, insert(:conversation), "## Mine")

      assert {:ok, %{live_proposals: 2}} =
               propose_document(document, insert(:conversation), "## Theirs")
    end

    # Different things, so one topic may hold both -- the index has `scope` in it
    # for exactly this.
    test "a topic may rewrite the body and rename the document at once" do
      %{document: document} = document_with_blocks(["One"])
      conversation = insert(:conversation)

      assert {:ok, %{proposal: body}} =
               propose_document(document, conversation, "## Rewritten")

      assert {:ok, %{proposal: title}} = propose_title(document, conversation, "Renamed")

      assert body.scope == :document
      assert title.scope == :title
      refute body.id == title.id
    end
  end

  describe "decide_title/3" do
    test "settles the argument and leaves the winner live" do
      %{document: document} = document_with_blocks(["One"])
      decider = insert(:actor)

      assert {:ok, %{proposal: mine}} =
               propose_title(document, insert(:conversation), "Mine")

      assert {:ok, %{proposal: theirs}} =
               propose_title(document, insert(:conversation), "Theirs")

      assert {:ok, adopted} = Documents.decide_title(document, theirs.id, decider.id)

      assert adopted.id == theirs.id
      assert adopted.status == :live
      assert Repo.reload!(mine).status == :rejected
      assert Repo.reload!(mine).decided_by_actor_id == decider.id
    end

    # The block slot and the title slot are different arguments; deciding one
    # must not reach into the other.
    test "refuses a proposal that is not in the title slot" do
      %{document: document, blocks: [block | _rest]} = document_with_blocks(["One"])
      conversation = insert(:conversation)
      actor = insert(:actor)

      assert {:ok, %{proposal: block_proposal}} =
               propose(document, block.block_id, conversation, "Tighter")

      assert {:error, :proposal_not_found, details} =
               Documents.decide_title(document, block_proposal.id, actor.id)

      assert details.scope == :title
    end
  end

  describe "decide_document/3" do
    # Committing one would settle it too, but only by changing the document at
    # the same time. This says which rewrite the document will take and leaves
    # when to take it to whoever commits.
    test "settles two competing rewrites and leaves the winner live" do
      %{document: document} = document_with_blocks(["One"])
      actor = insert(:actor)
      decider = insert(:actor)

      assert {:ok, %{proposal: mine}} =
               propose_document(document, insert(:conversation), "## Mine")

      assert {:ok, %{proposal: theirs}} =
               propose_document(document, insert(:conversation), "## Theirs")

      assert {:ok, adopted} = Documents.decide_document(document, theirs.id, decider.id)

      assert adopted.id == theirs.id
      assert adopted.status == :live
      assert Repo.reload!(mine).status == :rejected
      assert Documents.scope_contentions(document) == []

      # And the winner still has to be committed like anything else.
      assert {:ok, revision} = commit_document(document, actor, adopted)
      assert Enum.map(revision.blocks, & &1.content) == ["## Theirs"]
    end

    # A rewrite competes with another rewrite. Against a block proposal there is
    # nothing to choose: the two are not alternatives, and a commit supersedes
    # the block one rather than a decision rejecting it.
    test "refuses a proposal from another slot" do
      %{document: document, blocks: [block | _rest]} = document_with_blocks(["One"])
      actor = insert(:actor)

      assert {:ok, %{proposal: block_proposal}} =
               propose(document, block.block_id, insert(:conversation), "Tighter")

      assert {:error, :proposal_not_found, details} =
               Documents.decide_document(document, block_proposal.id, actor.id)

      assert details.scope == :document
    end
  end

  describe "commit_proposals/2 with a title proposal" do
    test "carries an uncontested title into the revision" do
      %{document: document} = document_with_blocks(["One"])
      conversation = insert(:conversation)
      actor = insert(:actor)

      assert {:ok, %{proposal: proposal}} =
               propose_title(document, conversation, "上线流程")

      assert {:ok, revision} = commit(document, actor)

      assert revision.title == "上线流程"
      assert Repo.reload!(proposal).status == :accepted
    end

    # A retitling is a change, so the commit is not empty for want of a block.
    test "commits a title with no block proposal standing" do
      %{document: document} = document_with_blocks(["One"])
      actor = insert(:actor)

      assert {:ok, _proposed} =
               propose_title(document, insert(:conversation), "Renamed")

      assert {:ok, revision} = commit(document, actor)
      assert revision.title == "Renamed"
      assert Enum.map(revision.blocks, & &1.content) == ["## One"]
    end

    test "a title and a block go in one revision" do
      %{document: document, blocks: [block | _rest]} = document_with_blocks(["One"])
      conversation = insert(:conversation)
      actor = insert(:actor)

      assert {:ok, _proposed} = propose(document, block.block_id, conversation, "Tighter")
      assert {:ok, _proposed} = propose_title(document, conversation, "Renamed")

      assert {:ok, revision} = commit(document, actor)
      assert revision.title == "Renamed"
      assert Enum.map(revision.blocks, & &1.content) == ["Tighter"]
    end

    # Left behind rather than holding up the rest, exactly as a contended block
    # is. The revision keeps the parent's title.
    test "leaves a contended title behind and commits the blocks" do
      %{document: document, blocks: [block | _rest]} = document_with_blocks(["One"])
      actor = insert(:actor)

      assert {:ok, _proposed} =
               propose(document, block.block_id, insert(:conversation), "Tighter")

      assert {:ok, %{proposal: mine}} =
               propose_title(document, insert(:conversation), "Mine")

      assert {:ok, %{proposal: theirs}} =
               propose_title(document, insert(:conversation), "Theirs")

      assert {:ok, revision} = commit(document, actor)

      assert revision.title == "Document"
      assert Enum.map(revision.blocks, & &1.content) == ["Tighter"]
      assert Repo.reload!(mine).status == :live
      assert Repo.reload!(theirs).status == :live
    end

    # Somebody typed a title. It wins, but it decides nothing about the
    # proposals -- nobody chose between them.
    test "a title in the commit attrs wins and settles nothing" do
      %{document: document} = document_with_blocks(["One"])
      actor = insert(:actor)

      assert {:ok, %{proposal: proposal}} =
               propose_title(document, insert(:conversation), "Proposed")

      assert {:ok, revision} =
               Documents.commit_proposals(document, %{
                 actor_id: actor.id,
                 base_revision_id: latest_revision_id(document),
                 title: "Typed by a person"
               })

      assert revision.title == "Typed by a person"
      assert Repo.reload!(proposal).status == :live
    end

    test "still refuses a commit with nothing standing at all" do
      %{document: document} = document_with_blocks(["One"])

      assert {:error, :nothing_to_commit, _details} = commit(document, insert(:actor))
    end
  end

  describe "rebase_document_proposal/2" do
    # The whole point: a stale proposal becomes committable again without going
    # back to the model.
    test "carries a rewrite across an edit that landed on another block" do
      %{document: document, blocks: [first, _second]} = document_with_blocks(["One", "Two"])
      conversation = insert(:conversation)
      actor = insert(:actor)

      assert {:ok, %{proposal: proposal}} =
               propose_document(document, conversation, "## One\n\n## Two, mine")

      assert {:ok, _proposed} =
               propose(document, first.block_id, insert(:conversation), "## One, theirs")

      assert {:ok, landed} = commit(document, actor)
      assert {:error, :stale_proposal, _details} = commit_document(document, actor, proposal)

      assert {:ok, rebased} = Documents.rebase_document_proposal(document, proposal.id)

      assert rebased.id == proposal.id
      assert rebased.base_revision_id == landed.id

      # Both edits survive, and it commits.
      assert {:ok, revision} = commit_document(document, actor, rebased)
      assert Enum.map(revision.blocks, & &1.content) == ["## One, theirs", "## Two, mine"]
    end

    test "carries an insertion across an edit elsewhere" do
      %{document: document, blocks: [first, _second]} = document_with_blocks(["One", "Two"])
      conversation = insert(:conversation)
      actor = insert(:actor)

      assert {:ok, %{proposal: proposal}} =
               propose_document(document, conversation, "## One\n\n## Middle\n\n## Two")

      assert {:ok, _proposed} =
               propose(document, first.block_id, insert(:conversation), "## One, theirs")

      assert {:ok, _landed} = commit(document, actor)
      assert {:ok, rebased} = Documents.rebase_document_proposal(document, proposal.id)
      assert {:ok, revision} = commit_document(document, actor, rebased)

      assert Enum.map(revision.blocks, & &1.content) == [
               "## One, theirs",
               "## Middle",
               "## Two"
             ]
    end

    # At the block grain, which is the grain every other argument here is at.
    test "reports a conflict when both sides rewrote the same block" do
      %{document: document, blocks: [first, _second]} = document_with_blocks(["One", "Two"])
      actor = insert(:actor)

      assert {:ok, %{proposal: proposal}} =
               propose_document(document, insert(:conversation), "## One, mine\n\n## Two")

      assert {:ok, _proposed} =
               propose(document, first.block_id, insert(:conversation), "## One, theirs")

      assert {:ok, _landed} = commit(document, actor)

      assert {:error, :rebase_conflict, details} =
               Documents.rebase_document_proposal(document, proposal.id)

      assert details.reason == :diverged
      assert details.block_ids == [first.block_id]

      # Nothing was changed, so the proposal is still there to be decided about.
      assert Repo.reload!(proposal).base_revision_id == proposal.base_revision_id
    end

    test "answers unchanged when the proposal is already current" do
      %{document: document} = document_with_blocks(["One"])

      assert {:ok, %{proposal: proposal}} =
               propose_document(document, insert(:conversation), "## Rewritten")

      assert {:ok, same} = Documents.rebase_document_proposal(document, proposal.id)
      assert same.base_revision_id == proposal.base_revision_id
      assert same.block_ops == proposal.block_ops
    end

    # What it wanted is already true, so there is nothing left to propose.
    test "reports no change when the landed revision already says what it wanted" do
      %{document: document, blocks: [first, _second]} = document_with_blocks(["One", "Two"])
      actor = insert(:actor)

      assert {:ok, %{proposal: proposal}} =
               propose_document(document, insert(:conversation), "## One, same\n\n## Two")

      assert {:ok, _proposed} =
               propose(document, first.block_id, insert(:conversation), "## One, same")

      assert {:ok, _landed} = commit(document, actor)

      assert {:error, :no_change_proposed, _details} =
               Documents.rebase_document_proposal(document, proposal.id)
    end

    test "refuses a proposal that is not a live document proposal" do
      %{document: document, blocks: [block | _rest]} = document_with_blocks(["One"])

      assert {:ok, %{proposal: block_proposal}} =
               propose(document, block.block_id, insert(:conversation), "Tighter")

      assert {:error, :proposal_not_found, _details} =
               Documents.rebase_document_proposal(document, block_proposal.id)
    end

    # The stored Markdown and the stored operations have to agree, or a person
    # reviews one thing and commits another.
    test "leaves the body and the operations describing the same document" do
      %{document: document, blocks: [first, _second]} = document_with_blocks(["One", "Two"])
      actor = insert(:actor)

      assert {:ok, %{proposal: proposal}} =
               propose_document(document, insert(:conversation), "## One\n\n## Two, mine")

      assert {:ok, _proposed} =
               propose(document, first.block_id, insert(:conversation), "## One, theirs")

      assert {:ok, _landed} = commit(document, actor)
      assert {:ok, rebased} = Documents.rebase_document_proposal(document, proposal.id)

      assert {:ok, from_body} = Documents.preview_blocks(rebased.content)

      assert {:ok, from_operations} =
               BlockOps.apply(document_blocks(document), rebased.block_ops)

      assert Enum.map(from_operations, & &1.content) == from_body
    end
  end

  describe "scope_contentions/1" do
    test "reports each document-level scope more than one topic is arguing over" do
      %{document: document} = document_with_blocks(["One"])

      assert {:ok, _proposed} = propose_title(document, insert(:conversation), "Mine")
      assert {:ok, _proposed} = propose_title(document, insert(:conversation), "Theirs")

      assert {:ok, _proposed} =
               propose_document(document, insert(:conversation), "## Mine")

      assert [%{scope: :title, proposals: proposals}] = Documents.scope_contentions(document)
      assert length(proposals) == 2

      # One rewrite is not an argument.
      assert {:ok, _proposed} =
               propose_document(document, insert(:conversation), "## Theirs")

      assert Enum.map(Documents.scope_contentions(document), & &1.scope) == [:document, :title]
    end

    # A per-block decision would not settle a whole-document argument, so it is
    # not reported as one.
    test "stays out of the block-level contention list" do
      %{document: document} = document_with_blocks(["One"])

      assert {:ok, _proposed} = propose_title(document, insert(:conversation), "Mine")
      assert {:ok, _proposed} = propose_title(document, insert(:conversation), "Theirs")

      assert Documents.contentions(document) == []
    end
  end

  describe "document_proposal_for_conversation/2" do
    test "answers with the topic's own rewrite and nobody else's" do
      %{document: document} = document_with_blocks(["One"])
      mine = insert(:conversation)
      theirs = insert(:conversation)

      assert {:ok, %{proposal: proposal}} = propose_document(document, mine, "## Mine")
      assert {:ok, _proposed} = propose_document(document, theirs, "## Theirs")

      assert Documents.document_proposal_for_conversation(document, mine.id).id == proposal.id
      refute Documents.document_proposal_for_conversation(document, insert(:conversation).id)
    end

    test "answers with nothing once the rewrite has been committed" do
      %{document: document} = document_with_blocks(["One"])
      conversation = insert(:conversation)
      actor = insert(:actor)

      assert {:ok, %{proposal: proposal}} =
               propose_document(document, conversation, "## Rewritten")

      assert {:ok, _revision} = commit_document(document, actor, proposal)
      refute Documents.document_proposal_for_conversation(document, conversation.id)
    end
  end

  describe "commit_proposals/2 with a document proposal" do
    test "writes every block the operations describe, in one revision" do
      %{document: document} = document_with_blocks(["One", "Two"])
      actor = insert(:actor)

      assert {:ok, %{proposal: proposal}} =
               propose_document(
                 document,
                 insert(:conversation),
                 "## Zero\n\n## One\n\n## Two, tighter"
               )

      assert {:ok, revision} = commit_document(document, actor, proposal)

      assert Enum.map(revision.blocks, & &1.content) == ["## Zero", "## One", "## Two, tighter"]
      assert Repo.reload!(proposal).status == :accepted
    end

    test "keeps the id of a block the rewrite left alone" do
      %{document: document, blocks: [first, _second]} = document_with_blocks(["One", "Two"])
      actor = insert(:actor)

      assert {:ok, %{proposal: proposal}} =
               propose_document(
                 document,
                 insert(:conversation),
                 "## One\n\n## Two, tighter"
               )

      assert {:ok, revision} = commit_document(document, actor, proposal)

      kept = Enum.find(revision.blocks, &(&1.content == "## One"))
      assert kept.block_id == first.block_id
    end

    # Named rather than adopted by default: it settles every block, so letting
    # one land implicitly would discard other topics' work with nobody choosing.
    test "is never adopted by a commit that did not name it" do
      %{document: document} = document_with_blocks(["One"])
      actor = insert(:actor)

      assert {:ok, _proposed} =
               propose_document(document, insert(:conversation), "## Rewritten")

      assert {:error, :nothing_to_commit, _details} = commit(document, actor)
    end

    # Their anchors may not survive it, so leaving them live would mean a commit
    # that later fails on an operation nobody wrote.
    test "supersedes the other live block and document proposals" do
      %{document: document, blocks: [block | _rest]} = document_with_blocks(["One", "Two"])
      actor = insert(:actor)

      assert {:ok, %{proposal: theirs}} =
               propose(document, block.block_id, insert(:conversation), "Their block")

      assert {:ok, %{proposal: rival}} =
               propose_document(document, insert(:conversation), "## Rival rewrite")

      assert {:ok, %{proposal: mine}} =
               propose_document(document, insert(:conversation), "## My rewrite")

      assert {:ok, _revision} = commit_document(document, actor, mine)

      assert Repo.reload!(mine).status == :accepted
      assert Repo.reload!(theirs).status == :superseded
      assert Repo.reload!(rival).status == :superseded
      assert Repo.reload!(rival).decided_by_actor_id == actor.id
    end

    # A title has no anchor to lose, so it is neither superseded nor ignored.
    test "adopts an uncontested title alongside it and leaves a contended one live" do
      %{document: document} = document_with_blocks(["One"])
      actor = insert(:actor)
      conversation = insert(:conversation)

      assert {:ok, %{proposal: body}} =
               propose_document(document, conversation, "## Rewritten")

      assert {:ok, %{proposal: title}} = propose_title(document, conversation, "Renamed")

      assert {:ok, revision} = commit_document(document, actor, body)

      assert revision.title == "Renamed"
      assert Repo.reload!(title).status == :accepted
    end

    test "leaves a contended title behind, as any other commit does" do
      %{document: document} = document_with_blocks(["One"])
      actor = insert(:actor)

      assert {:ok, %{proposal: body}} =
               propose_document(document, insert(:conversation), "## Rewritten")

      assert {:ok, %{proposal: mine}} =
               propose_title(document, insert(:conversation), "Mine")

      assert {:ok, %{proposal: theirs}} =
               propose_title(document, insert(:conversation), "Theirs")

      assert {:ok, revision} = commit_document(document, actor, body)

      assert revision.title == "Document"
      assert Repo.reload!(mine).status == :live
      assert Repo.reload!(theirs).status == :live
    end

    # The whole reason `base_revision_id` stops being merely a record here: the
    # operations cover blocks the proposal did not touch, so an old one would
    # revert everything that landed under it.
    test "refuses a proposal compiled against an older revision" do
      %{document: document, blocks: [block | _rest]} = document_with_blocks(["One", "Two"])
      actor = insert(:actor)

      assert {:ok, %{proposal: proposal}} =
               propose_document(document, insert(:conversation), "## One\n\n## Two, mine")

      # Something else lands underneath it.
      assert {:ok, _proposed} =
               propose(document, block.block_id, insert(:conversation), "## One, theirs")

      assert {:ok, landed} = commit(document, actor)

      assert {:error, :stale_proposal, details} = commit_document(document, actor, proposal)
      assert details.base_revision_id == proposal.base_revision_id
      assert details.current_revision_id == landed.id

      # Nothing was written and nothing was settled.
      assert Repo.reload!(proposal).status == :live
      assert latest_revision_id(document) == landed.id
    end

    test "a re-proposal after that is committable again" do
      %{document: document, blocks: [block | _rest]} = document_with_blocks(["One", "Two"])
      actor = insert(:actor)
      conversation = insert(:conversation)

      assert {:ok, _proposed} =
               propose_document(document, conversation, "## One\n\n## Two, mine")

      assert {:ok, _proposed} =
               propose(document, block.block_id, insert(:conversation), "## One, theirs")

      assert {:ok, _landed} = commit(document, actor)

      assert {:ok, %{proposal: refreshed}} =
               propose_document(document, conversation, "## One, theirs\n\n## Two, mine")

      assert {:ok, revision} = commit_document(document, actor, refreshed)
      assert Enum.map(revision.blocks, & &1.content) == ["## One, theirs", "## Two, mine"]
    end

    # An absent selection means "everything uncontested" in an ordinary commit.
    # It cannot mean that here: the operations already reach every block, so
    # adopting the rest on top would be a second claim nobody made.
    test "does not adopt block proposals the caller did not name" do
      %{document: document, blocks: [_first, second]} = document_with_blocks(["One", "Two"])
      actor = insert(:actor)

      assert {:ok, %{proposal: theirs}} =
               propose(document, second.block_id, insert(:conversation), "## Two, theirs")

      assert {:ok, %{proposal: proposal}} =
               propose_document(document, insert(:conversation), "## One\n\n## Two\n\n## Three")

      assert {:ok, revision} = commit_document(document, actor, proposal)

      assert Enum.map(revision.blocks, & &1.content) == ["## One", "## Two", "## Three"]
      assert Repo.reload!(theirs).status == :live
    end

    test "refuses a proposal that is not live, or not a document proposal" do
      %{document: document, blocks: [block | _rest]} = document_with_blocks(["One"])
      actor = insert(:actor)

      assert {:ok, %{proposal: block_proposal}} =
               propose(document, block.block_id, insert(:conversation), "Tighter")

      assert {:error, :proposal_not_found, details} =
               commit_document(document, actor, block_proposal)

      assert details.scope == :document
    end

    test "carries the proposer's summary when the committer wrote none" do
      %{document: document} = document_with_blocks(["One"])
      actor = insert(:actor)

      assert {:ok, %{proposal: proposal}} =
               Documents.propose_document(document, %{
                 conversation_id: insert(:conversation).id,
                 actor_id: actor.id,
                 content: "## Rewritten",
                 change_summary: "Split the intro out"
               })

      assert {:ok, revision} = commit_document(document, actor, proposal)
      assert revision.change_summary == "Split the intro out"
    end
  end

  # A document proposal claims the sequence, not every block's text. Adding a
  # section after Block 3 and rewriting Block 3 are answers to two different
  # questions, and refusing the pair -- which is what `scope` alone can tell --
  # made a person commit twice to say one thing.
  describe "commit_proposals/2 with a document proposal and block proposals" do
    test "a new section and a rewrite of the block before it land together" do
      %{document: document, blocks: [_first, second, third]} = three_blocks()
      actor = insert(:actor)

      {:ok, %{proposal: block_proposal}} =
        propose(document, second.block_id, insert(:conversation), "## Two, tighter")

      {:ok, %{proposal: document_proposal}} = propose_appended_section(document)

      assert {:ok, revision} =
               commit_document(document, actor, document_proposal, [second.block_id])

      assert Enum.map(revision.blocks, & &1.content) ==
               ["## One", "## Two, tighter", "## Three", "## Four"]

      assert Repo.reload!(document_proposal).status == :accepted
      assert Repo.reload!(block_proposal).status == :accepted

      # The insertion anchor is Block 3, which nothing moved or renamed.
      assert Enum.find(revision.blocks, &(&1.content == "## Three")).block_id == third.block_id
    end

    # The one the insertion hangs off. `insert_after` names it as a position and
    # `update` replaces its text; `block_id` survives both, so the anchor is
    # still there to resolve however the two are ordered.
    test "a new section and a rewrite of its own anchor land together" do
      %{document: document, blocks: [_first, _second, third]} = three_blocks()
      actor = insert(:actor)

      {:ok, %{proposal: block_proposal}} =
        propose(document, third.block_id, insert(:conversation), "## Three, tighter")

      {:ok, %{proposal: document_proposal}} = propose_appended_section(document)

      assert {:ok, revision} =
               commit_document(document, actor, document_proposal, [third.block_id])

      assert Enum.map(revision.blocks, & &1.content) ==
               ["## One", "## Two", "## Three, tighter", "## Four"]

      assert Repo.reload!(block_proposal).status == :accepted
    end

    test "carries every named block into the one revision" do
      %{document: document, blocks: [_first, second, third]} = three_blocks()
      actor = insert(:actor)

      {:ok, _proposed} = propose(document, second.block_id, insert(:conversation), "## Two, mine")

      {:ok, _proposed} =
        propose(document, third.block_id, insert(:conversation), "## Three, theirs")

      {:ok, %{proposal: document_proposal}} = propose_appended_section(document)

      selection = [second.block_id, third.block_id]

      assert {:ok, revision} = commit_document(document, actor, document_proposal, selection)

      assert Enum.map(revision.blocks, & &1.content) ==
               ["## One", "## Two, mine", "## Three, theirs", "## Four"]

      # One revision, not three: the whole selection is one change to the
      # document's history.
      assert revision.parent_id == document.latest_revision.id
    end

    # Both claim the same block's text. Committing them together would mean one
    # silently overruling the other, which is the decision this refuses to make
    # on somebody's behalf.
    test "refuses a block the document proposal rewrites" do
      %{document: document, blocks: [_first, second, _third]} = three_blocks()
      actor = insert(:actor)

      {:ok, %{proposal: block_proposal}} =
        propose(document, second.block_id, insert(:conversation), "## Two, mine")

      {:ok, %{proposal: document_proposal}} =
        propose_document(document, insert(:conversation), "## One\n\n## Two, theirs\n\n## Three")

      assert {:error, :conflicting_commit, details} =
               commit_document(document, actor, document_proposal, [second.block_id])

      assert details.block_ids == [second.block_id]

      assert latest_revision_id(document) == document.latest_revision.id
      assert Repo.reload!(document_proposal).status == :live
      assert Repo.reload!(block_proposal).status == :live
    end

    # Worse than overruled: after the delete there is no block left for the
    # update to name, and `BlockOps` would fail on an operation nobody wrote.
    test "refuses a block the document proposal deletes" do
      %{document: document, blocks: [_first, second, _third]} = three_blocks()
      actor = insert(:actor)

      {:ok, %{proposal: block_proposal}} =
        propose(document, second.block_id, insert(:conversation), "## Two, mine")

      {:ok, %{proposal: document_proposal}} =
        propose_document(document, insert(:conversation), "## One\n\n## Three")

      assert {:error, :conflicting_commit, details} =
               commit_document(document, actor, document_proposal, [second.block_id])

      assert details.block_ids == [second.block_id]
      assert Repo.reload!(block_proposal).status == :live
    end

    # A move claims where a block sits; an update claims what it says. Neither
    # changes a `block_id`, so the two compose rather than collide.
    #
    # `BlockDiff` never compiles a `move_after` -- it expresses a move as a
    # delete and an insert -- so this one is written by hand, which is also the
    # only way the operation reaches a proposal today.
    test "a move and a rewrite of the moved block land together" do
      %{document: document, blocks: [_first, _second, third]} = three_blocks()
      actor = insert(:actor)

      {:ok, %{proposal: block_proposal}} =
        propose(document, third.block_id, insert(:conversation), "## Three, tighter")

      {:ok, document_proposal} =
        insert_proposal(
          document_id: document.id,
          scope: :document,
          conversation_id: insert(:conversation).id,
          content: "## Three\n\n## One\n\n## Two",
          block_ops: [
            %{"op" => "move_after", "block_id" => third.block_id, "after_block_id" => nil}
          ],
          base_revision_id: latest_revision_id(document)
        )

      assert {:ok, revision} =
               commit_document(document, actor, document_proposal, [third.block_id])

      assert Enum.map(revision.blocks, & &1.content) ==
               ["## Three, tighter", "## One", "## Two"]

      assert Repo.reload!(block_proposal).status == :accepted
    end

    test "refuses a named block with no live proposal on it" do
      %{document: document, blocks: [_first, second, _third]} = three_blocks()
      actor = insert(:actor)

      {:ok, %{proposal: document_proposal}} = propose_appended_section(document)

      assert {:error, :no_live_proposal, details} =
               commit_document(document, actor, document_proposal, [second.block_id])

      assert details.block_id == second.block_id
    end

    test "refuses a named block that is still contended" do
      %{document: document, blocks: [_first, second, _third]} = three_blocks()
      actor = insert(:actor)

      {:ok, _proposed} = propose(document, second.block_id, insert(:conversation), "## Two, mine")
      {:ok, _proposed} = propose(document, second.block_id, insert(:conversation), "## Two, hers")

      {:ok, %{proposal: document_proposal}} = propose_appended_section(document)

      assert {:error, :unresolved_contention, details} =
               commit_document(document, actor, document_proposal, [second.block_id])

      assert details.block_ids == [second.block_id]
    end

    # The stale check comes first and is unchanged by any of this: a rewrite
    # compiled against an older revision would revert what landed under it
    # whether or not blocks were named alongside it.
    test "still refuses a document proposal compiled against an older revision" do
      %{document: document, blocks: [first, second, _third]} = three_blocks()
      actor = insert(:actor)

      {:ok, %{proposal: document_proposal}} = propose_appended_section(document)

      {:ok, _proposed} = propose(document, first.block_id, insert(:conversation), "## One, first")
      {:ok, landed} = commit(document, actor)

      {:ok, %{proposal: block_proposal}} =
        propose(document, second.block_id, insert(:conversation), "## Two, mine")

      assert {:error, :stale_proposal, details} =
               commit_document(document, actor, document_proposal, [second.block_id])

      assert details.current_revision_id == landed.id

      assert latest_revision_id(document) == landed.id
      assert Repo.reload!(document_proposal).status == :live
      assert Repo.reload!(block_proposal).status == :live
    end

    # Adding a chapter says nothing about the paragraphs elsewhere, so it is no
    # reason to throw away what other topics are still holding.
    test "leaves live proposals on the blocks it did not settle alone" do
      %{document: document, blocks: [first, second, _third]} = three_blocks()
      actor = insert(:actor)

      {:ok, %{proposal: untouched}} =
        propose(document, first.block_id, insert(:conversation), "## One, later")

      {:ok, %{proposal: adopted}} =
        propose(document, second.block_id, insert(:conversation), "## Two, tighter")

      {:ok, %{proposal: document_proposal}} = propose_appended_section(document)

      assert {:ok, _revision} =
               commit_document(document, actor, document_proposal, [second.block_id])

      assert Repo.reload!(adopted).status == :accepted
      assert Repo.reload!(untouched).status == :live
    end

    # A rival rewrite is superseded whatever it did: its base has just moved,
    # so it could not be committed again anyway.
    test "supersedes the other live document proposals" do
      %{document: document, blocks: [_first, second, _third]} = three_blocks()
      actor = insert(:actor)

      {:ok, _proposed} = propose(document, second.block_id, insert(:conversation), "## Two, mine")

      {:ok, %{proposal: rival}} =
        propose_document(document, insert(:conversation), "## Rival rewrite")

      {:ok, %{proposal: document_proposal}} = propose_appended_section(document)

      assert {:ok, _revision} =
               commit_document(document, actor, document_proposal, [second.block_id])

      assert Repo.reload!(rival).status == :superseded
      assert Repo.reload!(rival).decided_by_actor_id == actor.id
    end

    test "writes nothing at all when a later step of the commit fails" do
      %{document: document, blocks: [_first, second, _third]} = three_blocks()
      actor = insert(:actor)
      foreign = insert(:annotation, document: insert(:document))

      {:ok, %{proposal: block_proposal}} =
        propose(document, second.block_id, insert(:conversation), "## Two, tighter")

      {:ok, %{proposal: document_proposal}} = propose_appended_section(document)

      revisions_before = length(Documents.list_revisions(document))

      assert {:error, :annotation_not_found, _details} =
               Documents.commit_proposals(document, %{
                 actor_id: actor.id,
                 base_revision_id: latest_revision_id(document),
                 document_proposal_id: document_proposal.id,
                 block_ids: [second.block_id],
                 confirm_annotation_ids: [foreign.id]
               })

      assert length(Documents.list_revisions(document)) == revisions_before
      assert Repo.reload!(document_proposal).status == :live
      assert Repo.reload!(block_proposal).status == :live
    end
  end

  defp three_blocks, do: document_with_blocks(["One", "Two", "Three"])

  # A section after Block 3 and nothing else: one `insert_after`, anchored on a
  # block that survives the whole list.
  defp propose_appended_section(document) do
    propose_document(document, insert(:conversation), "## One\n\n## Two\n\n## Three\n\n## Four")
  end

  defp commit_document(document, actor, proposal) do
    Documents.commit_proposals(document, %{
      actor_id: actor.id,
      base_revision_id: latest_revision_id(document),
      document_proposal_id: proposal.id
    })
  end

  defp commit_document(document, actor, proposal, block_ids) do
    Documents.commit_proposals(document, %{
      actor_id: actor.id,
      base_revision_id: latest_revision_id(document),
      document_proposal_id: proposal.id,
      block_ids: block_ids
    })
  end

  defp propose_document(document, conversation, markdown) do
    Documents.propose_document(document, %{
      conversation_id: conversation.id,
      content: markdown
    })
  end

  defp propose_title(document, conversation, content) do
    Documents.propose_title(document, %{
      conversation_id: conversation.id,
      content: content
    })
  end

  defp commit(document, actor) do
    Documents.commit_proposals(document, %{
      actor_id: actor.id,
      base_revision_id: latest_revision_id(document)
    })
  end

  defp insert_proposal(attrs) do
    attrs = Map.new(attrs)

    defaults = %{
      content: "Proposed",
      actor_id: insert(:actor).id
    }

    defaults
    |> Map.merge(attrs)
    |> then(&BlockProposal.changeset(%BlockProposal{}, &1))
    |> Repo.insert()
  end

  defp document_blocks(document) do
    Documents.get_document!(document.id).latest_revision.blocks
    |> Enum.sort_by(& &1.position)
  end

  # No actor: a proposal is attributed to the topic's assistant, and a caller
  # able to name an author could name the wrong one.
  defp default_assistant do
    case Setup.ensure_default_assistant() do
      {:created, :assistant, assistant} -> assistant
      {:present, :assistant, assistant} -> assistant
    end
  end

  defp plain_chat do
    insert(:conversation,
      mode: :chat,
      assistant_actor: nil,
      provider: "openai",
      model: "gpt-5.4",
      thinking_level: "medium"
    )
  end

  defp propose(document, block_id, conversation, content) do
    Documents.propose_block(document, %{
      block_id: block_id,
      conversation_id: conversation.id,
      content: content
    })
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

  defp commit_attrs(document, committer, conversation) do
    %{
      actor_id: committer.id,
      base_revision_id: latest_revision_id(document),
      source_conversation_id: conversation.id
    }
  end
end
