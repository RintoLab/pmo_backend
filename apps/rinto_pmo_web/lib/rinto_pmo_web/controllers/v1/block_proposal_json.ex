defmodule RintoPMOWeb.V1.BlockProposalJSON do
  alias RintoPMO.Documents.BlockProposal

  @doc """
  A document's proposals, and what each still means against the document as it
  now stands.

  `meta.current_revision_id` is the revision the whole list was compared
  against, read from the same snapshot. A client pairing one revision's diff
  with another revision's id would publish against the wrong thing and have no
  way of knowing.
  """
  def index(%{review: review}) do
    %{
      data: Enum.map(review.proposals, &detail/1),
      meta: %{current_revision_id: review.current_revision_id}
    }
  end

  def show(%{detail: detail}) do
    %{data: detail(detail), meta: %{current_revision_id: detail.current_revision_id}}
  end

  def proposed(%{
        proposed: %{
          proposals: proposals,
          summary: summary,
          superseded: superseded,
          contended: contended
        }
      }) do
    %{
      data: Enum.map(proposals, &data/1),
      summary: summary,
      superseded: superseded,
      # Named per proposal, because one rewrite can walk into several
      # independent arguments and "this request was contended" says nothing a
      # person can act on.
      contended:
        Enum.map(contended, fn entry ->
          %{
            proposal_id: entry.proposal_id,
            conflicting_proposal_ids: entry.conflicting_proposal_ids
          }
        end)
    }
  end

  def contentions(%{contentions: contentions}) do
    %{
      data:
        Enum.map(contentions, fn contention ->
          %{
            reason: contention.reason,
            proposal_ids: contention.proposal_ids,
            scope: contention.scope,
            block_id: contention.block_id
          }
        end)
    }
  end

  def blocks(%{
        revision_id: revision_id,
        blocks: blocks,
        title: title,
        unapplicable: unapplicable
      }) do
    %{
      revision_id: revision_id,
      title: title,
      data: Enum.map(blocks, &block/1),
      # This topic's own proposals that could not be laid over the document, and
      # what stopped each of them. Dropped silently, they would be written again
      # from scratch on the next turn.
      unapplicable: unapplicable
    }
  end

  @doc false
  def detail(detail) do
    detail.proposal
    |> data()
    |> Map.merge(%{
      # What this proposal still means against the current body. Derived on
      # every read rather than stored, because the answer changes when the
      # document does and a stored one would go quietly wrong.
      state: detail.state,
      reason: detail.reason,
      adopted: detail.adopted,
      # An adoption made against words that have since changed. Told apart from
      # never having been adopted: one is an argument nobody settled, the other
      # is a settlement that needs making again.
      adoption_stale: detail.adoption_stale,
      conflicting_proposal_ids: detail.conflicting_proposal_ids
    })
  end

  @doc false
  def data(%BlockProposal{} = proposal) do
    %{
      id: proposal.id,
      document_id: proposal.document_id,
      scope: proposal.scope,
      operation: proposal.operation,
      block_id: proposal.block_id,
      after_block_id: proposal.after_block_id,
      # Which written sequence of insertions this belongs to, and where in it.
      # Taking the first and the third of three still leaves them in order.
      run_id: proposal.run_id,
      run_ordinal: proposal.run_ordinal,
      conversation_id: proposal.conversation_id,
      actor_id: proposal.actor_id,
      content: proposal.content,
      change_summary: proposal.change_summary,
      base_revision_id: proposal.base_revision_id,
      staged: proposal.staged,
      status: proposal.status,
      accepted_revision_id: proposal.accepted_revision_id,
      supersedes_id: proposal.supersedes_id,
      decided_by_actor_id: proposal.decided_by_actor_id,
      decided_at: proposal.decided_at,
      decided_reason: proposal.decided_reason,
      inserted_at: proposal.inserted_at,
      updated_at: proposal.updated_at
    }
  end

  defp block(block) do
    %{
      block_id: block.block_id,
      position: block.position,
      content: block.content,
      proposal_id: block.proposal_id,
      proposed: block.proposed?,
      # A count, never the text. Reconciling versions is the human's decision;
      # this exists only so a topic knows it is not alone in the block.
      other_proposals: block.other_proposals
    }
  end
end
