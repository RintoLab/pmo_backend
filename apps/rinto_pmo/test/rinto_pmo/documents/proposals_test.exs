defmodule RintoPMO.Documents.ProposalsTest do
  use RintoPMO.DataCase, async: true

  alias RintoPMO.Annotations
  alias RintoPMO.AnnotationsMock
  alias RintoPMO.Documents
  alias RintoPMO.Documents.BlockProposal

  setup do
    # Commit resolves annotations through the injected context; these tests are
    # about what actually lands in the database, so it runs for real.
    stub_with(AnnotationsMock, Annotations)
    :ok
  end

  describe "propose_block/2" do
    test "records a topic's proposal and reports it stands alone" do
      %{document: document, blocks: [block | _rest]} = document_with_blocks(["One", "Two"])
      conversation = insert(:conversation)
      actor = insert(:actor)

      assert {:ok, %{proposal: %BlockProposal{} = proposal, live_proposals: 1}} =
               propose(document, block.block_id, conversation, actor, "Tighter one")

      assert proposal.status == :live
      assert proposal.block_id == block.block_id
      assert proposal.conversation_id == conversation.id
      assert proposal.actor_id == actor.id
      assert proposal.content == "Tighter one"
      assert proposal.base_revision_id == latest_revision_id(document)
    end

    test "a topic revising the same block keeps exactly one live proposal" do
      %{document: document, blocks: [block | _rest]} = document_with_blocks(["One"])
      conversation = insert(:conversation)
      actor = insert(:actor)

      ids =
        for round <- 1..5 do
          assert {:ok, %{proposal: proposal, live_proposals: 1}} =
                   propose(document, block.block_id, conversation, actor, "Attempt #{round}")

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
      actor = insert(:actor)

      assert {:ok, %{live_proposals: 1}} =
               propose(document, block.block_id, first, actor, "Version A")

      assert {:ok, %{live_proposals: 2}} =
               propose(document, block.block_id, second, actor, "Version B")

      assert [%{block_id: block_id, proposals: proposals}] = Documents.contentions(document)
      assert block_id == block.block_id
      assert Enum.map(proposals, & &1.status) == [:live, :live]
      assert Enum.map(proposals, & &1.content) |> Enum.sort() == ["Version A", "Version B"]
    end

    test "different blocks do not contend" do
      %{document: document, blocks: [first_block, second_block]} =
        document_with_blocks(["One", "Two"])

      actor = insert(:actor)

      {:ok, _} = propose(document, first_block.block_id, insert(:conversation), actor, "A")
      {:ok, _} = propose(document, second_block.block_id, insert(:conversation), actor, "B")

      assert Documents.contentions(document) == []
    end

    test "refuses a block the document does not have" do
      %{document: document} = document_with_blocks(["One"])
      stray = UUIDv7.generate()

      assert {:error, :unknown_block, %{block_id: ^stray}} =
               propose(document, stray, insert(:conversation), insert(:actor), "Nowhere")
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
      actor = insert(:actor)

      {:ok, _} = propose(document, first_block.block_id, mine, actor, "My version")
      {:ok, _} = propose(document, first_block.block_id, theirs, actor, "Their version")

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

      {:ok, _} = propose(document, block.block_id, theirs, insert(:actor), "Their version")

      assert [only] = Documents.blocks_for_conversation(document, bystander.id)
      assert only.content == "## Original"
      refute only.proposed?
      assert only.other_proposals == 1
    end
  end

  describe "decide_block/4" do
    test "rejects every proposal but one, leaving the winner pending" do
      %{document: document, blocks: [block | _rest]} = document_with_blocks(["One"])
      actor = insert(:actor)

      {:ok, %{proposal: keeper}} =
        propose(document, block.block_id, insert(:conversation), actor, "Version A")

      {:ok, %{proposal: loser}} =
        propose(document, block.block_id, insert(:conversation), actor, "Version B")

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
      author = insert(:actor)
      committer = insert(:actor)

      {:ok, %{proposal: proposal}} =
        propose(document, first_block.block_id, conversation, author, "Rewritten one")

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
      # The block is attributed to whoever wrote the text, not whoever approved.
      assert Enum.map(blocks, & &1.actor_id) == [author.id, second_block.actor_id]

      accepted = Repo.get!(BlockProposal, proposal.id)
      assert accepted.status == :accepted
      assert accepted.decided_by_actor_id == committer.id
    end

    test "resolves the named annotations against the new revision" do
      %{document: document, blocks: [block | _rest]} = document_with_blocks(["Original"])
      settled = insert(:annotation, document: document)
      untouched = insert(:annotation, document: document)

      {:ok, _} = propose(document, block.block_id, insert(:conversation), insert(:actor), "New")

      assert {:ok, revision} =
               Documents.commit_proposals(document, %{
                 actor_id: insert(:actor).id,
                 base_revision_id: latest_revision_id(document),
                 resolve_annotation_ids: [settled.id]
               })

      settled = Repo.get!(RintoPMO.Annotations.Annotation, settled.id)
      assert settled.status == :resolved
      assert settled.resolved_by_revision_id == revision.id

      # One discussion may touch three annotations and settle two; resolution
      # is named per annotation, never inferred.
      assert Repo.get!(RintoPMO.Annotations.Annotation, untouched.id).status == :open
    end

    test "refuses a contended block but not the blocks beside it" do
      %{document: document, blocks: [contended_block, quiet_block]} =
        document_with_blocks(["Contended", "Quiet"])

      actor = insert(:actor)
      first = insert(:conversation)
      second = insert(:conversation)

      {:ok, _} = propose(document, contended_block.block_id, first, actor, "Version A")
      {:ok, _} = propose(document, contended_block.block_id, second, actor, "Version B")
      {:ok, _} = propose(document, quiet_block.block_id, first, actor, "Uncontested")

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

      {:ok, _} = propose(document, contended_block.block_id, first, actor, "Version A")
      {:ok, _} = propose(document, contended_block.block_id, second, actor, "Version B")
      {:ok, _} = propose(document, quiet_block.block_id, first, actor, "Uncontested")

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
        propose(document, block.block_id, insert(:conversation), actor, "Version A")

      {:ok, _} = propose(document, block.block_id, insert(:conversation), actor, "Version B")

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

      {:ok, _} = propose(document, block.block_id, insert(:conversation), actor, "First")

      {:ok, _committed} =
        Documents.commit_proposals(document, %{actor_id: actor.id, base_revision_id: stale})

      {:ok, _} = propose(document, block.block_id, insert(:conversation), actor, "Second")

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
        propose(document, block.block_id, insert(:conversation), actor, "New text")

      revisions_before = length(Documents.list_revisions(document))

      assert {:error, :annotation_not_found, %{annotation_id: _id}} =
               Documents.commit_proposals(document, %{
                 actor_id: actor.id,
                 base_revision_id: latest_revision_id(document),
                 resolve_annotation_ids: [foreign.id]
               })

      # All three moves are one transaction: a revision that settled nothing,
      # or a proposal marked accepted by a commit that never landed, would each
      # leave the record lying.
      assert length(Documents.list_revisions(document)) == revisions_before
      assert Repo.get!(BlockProposal, proposal.id).status == :live
      assert Repo.get!(RintoPMO.Annotations.Annotation, foreign.id).status == :open
    end

    test "a rejected proposal is not committed" do
      %{document: document, blocks: [block | _rest]} = document_with_blocks(["Original"])
      actor = insert(:actor)

      {:ok, %{proposal: keeper}} =
        propose(document, block.block_id, insert(:conversation), actor, "Kept")

      {:ok, %{proposal: loser}} =
        propose(document, block.block_id, insert(:conversation), actor, "Dropped")

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

  defp propose(document, block_id, conversation, actor, content) do
    Documents.propose_block(document, %{
      block_id: block_id,
      conversation_id: conversation.id,
      actor_id: actor.id,
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
end
