defmodule RintoPMOWeb.V1.BlockProposalJSON do
  alias RintoPMO.Documents.BlockProposal

  def index(%{proposals: proposals}) do
    %{data: Enum.map(proposals, &data/1)}
  end

  def show(%{proposal: proposal}) do
    %{data: data(proposal)}
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
      # Every affected slot is named because one request can now write several
      # rows and encounter more than one independent contention.
      contended: contended
    }
  end

  def contentions(%{contentions: contentions, scope_contentions: scope_contentions}) do
    %{
      data:
        Enum.map(contentions, fn %{block_id: block_id, proposals: proposals} ->
          %{block_id: block_id, proposals: Enum.map(proposals, &data/1)}
        end),
      # A separate key, because these cannot be marked on a block and no
      # per-block decision would settle them.
      document_scopes:
        Enum.map(scope_contentions, fn contention ->
          %{
            scope: contention.scope,
            proposals: Enum.map(contention.proposals, &data/1)
          }
          |> maybe_put(:overlaps_block_ids, Map.get(contention, :overlaps_block_ids))
        end)
    }
  end

  def blocks(%{
        revision_id: revision_id,
        blocks: blocks,
        document_proposal: document_proposal
      }) do
    %{
      revision_id: revision_id,
      data: Enum.map(blocks, &block/1),
      # Present when this topic has a whole-document rewrite standing. The block
      # list above still describes the document without it; the rewrite is a
      # different view of the same topic's intent, rendered from its `block_ops`.
      document_proposal: document_proposal && data(document_proposal)
    }
  end

  @doc false
  def data(%BlockProposal{} = proposal) do
    %{
      id: proposal.id,
      document_id: proposal.document_id,
      scope: proposal.scope,
      block_id: proposal.block_id,
      conversation_id: proposal.conversation_id,
      actor_id: proposal.actor_id,
      content: proposal.content,
      # The operations the content compiles into, so a client can render the
      # diff a person is being asked to approve rather than two bodies to
      # compare by eye. Absent on the scopes that have no blocks to operate on.
      block_ops: proposal.block_ops,
      change_summary: proposal.change_summary,
      base_revision_id: proposal.base_revision_id,
      status: proposal.status,
      decided_by_actor_id: proposal.decided_by_actor_id,
      decided_at: proposal.decided_at,
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

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
