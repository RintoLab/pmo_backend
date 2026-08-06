defmodule RintoPMOWeb.V1.BlockProposalJSON do
  alias RintoPMO.Documents.BlockProposal

  def index(%{proposals: proposals}) do
    %{data: Enum.map(proposals, &data/1)}
  end

  def show(%{proposal: proposal}) do
    %{data: data(proposal)}
  end

  def proposed(%{proposed: %{proposal: proposal, live_proposals: live_proposals}}) do
    %{
      data: data(proposal),
      # Returned with the proposal so a topic learns it has walked into a
      # contention without asking again -- and before it builds further on the
      # assumption that its version is the one that will land.
      live_proposals: live_proposals,
      contended: live_proposals > 1
    }
  end

  def contentions(%{contentions: contentions}) do
    %{
      data:
        Enum.map(contentions, fn %{block_id: block_id, proposals: proposals} ->
          %{block_id: block_id, proposals: Enum.map(proposals, &data/1)}
        end)
    }
  end

  def blocks(%{blocks: blocks}) do
    %{data: Enum.map(blocks, &block/1)}
  end

  @doc false
  def data(%BlockProposal{} = proposal) do
    %{
      id: proposal.id,
      document_id: proposal.document_id,
      block_id: proposal.block_id,
      conversation_id: proposal.conversation_id,
      actor_id: proposal.actor_id,
      content: proposal.content,
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
end
