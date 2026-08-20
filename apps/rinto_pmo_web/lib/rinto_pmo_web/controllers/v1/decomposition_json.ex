defmodule RintoPMOWeb.V1.DecompositionJSON do
  @moduledoc """
  One attempt to break a document down.

  `data/1` is public because `RintoPMOWeb.DocumentChannel` pushes the same
  shape down the socket that this renders over HTTP. One shape, so a client
  renders an attempt the same way whether it arrived by polling once or by
  watching it change.
  """

  alias RintoPMO.Documents.Decomposition

  def show(%{decomposition: nil}), do: %{data: nil}
  def show(%{decomposition: decomposition}), do: %{data: data(decomposition)}

  @doc """
  The attempt as every caller sees it.
  """
  def data(%Decomposition{} = decomposition) do
    %{
      id: decomposition.id,
      source_document_id: decomposition.source_document_id,
      result_document_id: decomposition.result_document_id,
      status: decomposition.status,
      error: decomposition.error,
      inserted_at: decomposition.inserted_at,
      updated_at: decomposition.updated_at
    }
  end
end
