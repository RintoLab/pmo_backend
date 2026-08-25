defmodule RintoPMOWeb.V1.SearchJSON do
  @moduledoc """
  What a search found.

  **`uri` is the field that matters.** It is the canonical address of the
  result, which means a model can paste it straight into a body and a client
  can hand it to `POST /references/resolve` or `GET /backlinks` unchanged.
  Nothing has to assemble an id from parts, which is the whole reason results
  are addressed rather than described.

  `score` is the reranker's, not a cosine distance: higher is better, and the
  scale is the model's own rather than anything to threshold against across
  queries.
  """

  def index(%{results: results}), do: %{data: Enum.map(results, &data/1)}

  @doc """
  One result.
  """
  def data(result) do
    %{
      uri: result.uri,
      type: result.type,
      title: result.title,
      excerpt: result.excerpt,
      document_id: result.document_id,
      document_title: result.document_title,
      score: result.score,
      archived: result.archived
    }
  end
end
