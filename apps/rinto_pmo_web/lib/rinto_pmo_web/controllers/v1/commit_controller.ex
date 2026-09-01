defmodule RintoPMOWeb.V1.CommitController do
  use RintoPMOWeb, :controller

  alias RintoPMO.Utils
  alias RintoPMOWeb.Plugs.ActorToken

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

  One person commits, so `actor_id` is the token's and every entry gets the
  same one -- the single-document call's rule, applied to the batch. An entry
  naming its own author would be a caller deciding who agreed to what.
  """
  def create(conn, params) do
    with {:ok, entries} <- entries(params, ActorToken.current_actor!(conn).id),
         {:ok, revisions} <- Utils.module(:documents).commit_many(entries) do
      conn
      |> put_status(:created)
      |> put_view(json: RintoPMOWeb.V1.DocumentRevisionJSON)
      |> render(:index, revisions: revisions)
    end
  end

  defp entries(%{"commits" => commits}, actor_id) when is_list(commits) and commits != [] do
    if Enum.all?(commits, &commit_shaped?/1) do
      # Loaded here rather than in the context, so that a document that is not
      # there is the same `404` it is everywhere else in this API -- and so
      # that it happens before a transaction is open.
      {:ok, Enum.map(commits, &{document(&1), attrs(&1, actor_id)})}
    else
      {:error, :bad_request, %{"commits" => ["each entry needs a document_id"]}}
    end
  end

  defp entries(_params, _actor_id) do
    {:error, :bad_request, %{"commits" => ["must be a non-empty list"]}}
  end

  defp attrs(commit, actor_id) do
    commit
    |> Map.delete("document_id")
    |> Map.put("actor_id", actor_id)
  end

  defp commit_shaped?(commit) do
    is_map(commit) and is_binary(Map.get(commit, "document_id"))
  end

  defp document(commit) do
    Utils.module(:documents).get_document!(Map.fetch!(commit, "document_id"))
  end
end
