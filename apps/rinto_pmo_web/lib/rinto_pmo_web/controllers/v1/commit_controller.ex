defmodule RintoPMOWeb.V1.CommitController do
  use RintoPMOWeb, :controller

  alias RintoPMO.Utils

  @doc """
  Commits several documents at once, in one transaction.

  The endpoint behind one review screen and one button. A discussion that
  changed a design usually changed more than one document, and half of that
  landing is the worst outcome available -- the documents then disagree, and
  nothing records which half is the new answer.

  Each entry is what `POST /documents/{id}/commit` takes, plus the
  `document_id` naming what it is against. Nothing new is stored: this writes
  one revision per document exactly as the single-document call would, and
  there is no batch record. It is a verb, not a noun.

  Any entry failing rolls the whole thing back, and the error names the
  document it happened in.
  """
  def create(conn, params) do
    with {:ok, entries} <- entries(params),
         {:ok, revisions} <- Utils.module(:documents).commit_many(entries) do
      conn
      |> put_status(:created)
      |> put_view(json: RintoPMOWeb.V1.DocumentRevisionJSON)
      |> render(:index, revisions: revisions)
    end
  end

  defp entries(%{"commits" => commits}) when is_list(commits) and commits != [] do
    if Enum.all?(commits, &commit_shaped?/1) do
      # Loaded here rather than in the context, so that a document that is not
      # there is the same `404` it is everywhere else in this API -- and so
      # that it happens before a transaction is open.
      {:ok, Enum.map(commits, &{document(&1), Map.delete(&1, "document_id")})}
    else
      {:error, :bad_request, %{"commits" => ["each entry needs a document_id"]}}
    end
  end

  defp entries(_params) do
    {:error, :bad_request, %{"commits" => ["must be a non-empty list"]}}
  end

  defp commit_shaped?(commit) do
    is_map(commit) and is_binary(Map.get(commit, "document_id"))
  end

  defp document(commit) do
    Utils.module(:documents).get_document!(Map.fetch!(commit, "document_id"))
  end
end
