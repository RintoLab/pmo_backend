defmodule RintoPMOWeb.V1.DocumentRevisionController do
  use RintoPMOWeb, :controller

  alias RintoPMO.Utils
  alias RintoPMOWeb.Plugs.ActorToken

  def index(conn, %{"document_id" => document_id}) do
    document = get_document!(document_id)
    revisions = Utils.module(:documents).list_revisions(document)

    render(conn, :index, revisions: revisions)
  end

  def show(conn, %{"document_id" => document_id, "revision_id" => revision_id}) do
    document = get_document!(document_id)
    revision = Utils.module(:documents).get_revision!(document, revision_id)

    render(conn, :show, revision: revision)
  end

  @doc """
  Writes a revision directly, credited to whoever is calling.

  Writing a revision is how a *person* changes a document -- an AI proposes --
  so every block this touches is credited to the token's actor rather than to
  whoever each operation named. Blocks the revision leaves alone keep the
  author they already had, which is the whole point of attributing per block
  and not per revision.

  `commit_proposals/2` builds its operations from the proposals themselves and
  does not come through here, so a committed block still belongs to the AI that
  proposed it.
  """
  def create(conn, %{"document_id" => document_id} = params) do
    document = get_document!(document_id)

    revision_params =
      params
      |> Map.delete("document_id")
      |> credit(ActorToken.current_actor!(conn).id)

    with {:ok, revision} <- Utils.module(:documents).create_revision(document, revision_params) do
      conn
      |> put_status(:created)
      |> render(:show, revision: revision)
    end
  end

  # Left alone when it is not a list of objects: a malformed `block_ops` is the
  # context's error to name, and rewriting it here would turn one bad shape
  # into a different bad shape.
  defp credit(%{"block_ops" => operations} = params, actor_id) when is_list(operations) do
    Map.put(params, "block_ops", Enum.map(operations, &put_actor(&1, actor_id)))
  end

  defp credit(params, _actor_id), do: params

  defp put_actor(operation, actor_id) when is_map(operation) do
    Map.put(operation, "actor_id", actor_id)
  end

  defp put_actor(operation, _actor_id), do: operation

  @doc """
  Turns the chosen proposals into a revision.

  One call, three things, one transaction: the revision is written, the
  annotations named as settled are resolved against it, and the proposals it
  used are accepted. Commit is the only moment at which someone has both
  decided and changed the document, so it is the only natural place for an
  annotation to be resolved.

  A block with an undecided contention is refused, but only that block: the
  rest of the selection goes through.

  Committing is a person's action, so `actor_id` is the token's -- the same
  rule `POST /documents/{id}/proposals/{id}/decide` follows, and for the same
  reason: a body able to name somebody else would let an agent record a person
  as having agreed to its own change.
  """
  def commit(conn, %{"document_id" => document_id} = params) do
    document = get_document!(document_id)

    attrs =
      params
      |> Map.delete("document_id")
      |> Map.put("actor_id", ActorToken.current_actor!(conn).id)

    with {:ok, revision} <- Utils.module(:documents).commit_proposals(document, attrs) do
      conn
      |> put_status(:created)
      |> render(:show, revision: revision)
    end
  end

  defp get_document!(document_id) do
    Utils.module(:documents).get_document!(document_id)
  end
end
