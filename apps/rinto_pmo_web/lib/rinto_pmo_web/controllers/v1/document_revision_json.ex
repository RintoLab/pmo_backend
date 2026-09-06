defmodule RintoPMOWeb.V1.DocumentRevisionJSON do
  alias RintoPMO.Documents.DocumentBlock
  alias RintoPMO.Documents.DocumentRevision

  def index(%{revisions: revisions}) do
    %{data: Enum.map(revisions, &summary/1)}
  end

  def show(%{revision: revision}) do
    %{data: data(revision)}
  end

  @doc """
  What one publish did.

  `data` is the revision it wrote, or `null` when every selected proposal had
  already been applied -- which writes nothing, and says so rather than creating
  a revision identical to its parent. `meta` names what actually happened to
  each proposal, because "it worked" is not enough to redraw a review screen
  with: a candidate that lost has to disappear from it, and one that turned out
  to be already applied has to stop asking to be taken.
  """
  def published(%{publication: publication}) do
    %{
      data: publication.revision && data(publication.revision),
      meta: meta(publication)
    }
  end

  def published_many(%{publications: publications}) do
    %{
      data:
        Enum.map(publications, fn publication ->
          publication.revision && data(publication.revision)
        end),
      meta: Enum.map(publications, &meta/1)
    }
  end

  defp meta(publication) do
    %{
      result: publication.result,
      document_id: publication.document_id,
      current_revision_id: publication.current_revision_id,
      accepted_proposal_ids: publication.accepted,
      # Beaten by something this publish applied, and only by that: a proposal
      # about a different paragraph is still true and is still standing.
      superseded_proposal_ids: publication.superseded,
      # Already true before this ran. Not accepted -- no publish applied them --
      # and nothing was superseded on their account.
      already_applied_proposal_ids: publication.already_applied
    }
  end

  def summary(%DocumentRevision{} = revision) do
    %{
      id: revision.id,
      document_id: revision.document_id,
      parent_id: revision.parent_id,
      title: revision.title,
      change_summary: revision.change_summary,
      # Which discussion produced this. "What did that discussion change?" is
      # then a query rather than an entity anyone had to store.
      source_conversation_id: revision.source_conversation_id,
      inserted_at: revision.inserted_at
    }
  end

  def data(%DocumentRevision{} = revision) do
    revision
    |> summary()
    |> Map.put(:blocks, blocks(revision))
  end

  defp blocks(%DocumentRevision{blocks: blocks}) when is_list(blocks) do
    Enum.map(blocks, &block_data/1)
  end

  defp blocks(%DocumentRevision{}), do: []

  defp block_data(%DocumentBlock{} = block) do
    %{
      block_id: block.block_id,
      actor_id: block.actor_id,
      content: block.content,
      position: block.position
    }
  end
end
