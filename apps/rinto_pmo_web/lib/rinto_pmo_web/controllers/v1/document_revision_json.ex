defmodule RintoPMOWeb.V1.DocumentRevisionJSON do
  alias RintoPMO.Documents.DocumentBlock
  alias RintoPMO.Documents.DocumentRevision

  def index(%{revisions: revisions}) do
    %{data: Enum.map(revisions, &summary/1)}
  end

  def show(%{revision: revision}) do
    %{data: data(revision)}
  end

  def summary(%DocumentRevision{} = revision) do
    %{
      id: revision.id,
      document_id: revision.document_id,
      parent_id: revision.parent_id,
      title: revision.title,
      change_summary: revision.change_summary,
      inserted_at: revision.inserted_at
    }
  end

  def data(%DocumentRevision{} = revision) do
    revision
    |> summary()
    |> Map.put(:blocks, Enum.map(revision.blocks, &block_data/1))
  end

  defp block_data(%DocumentBlock{} = block) do
    %{
      block_id: block.block_id,
      actor_id: block.actor_id,
      content: block.content,
      position: block.position
    }
  end
end
