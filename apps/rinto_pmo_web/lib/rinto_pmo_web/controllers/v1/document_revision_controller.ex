defmodule RintoPMOWeb.V1.DocumentRevisionController do
  use RintoPMOWeb, :controller

  alias RintoPMO.Utils

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

  def create(conn, %{"document_id" => document_id} = params) do
    document = get_document!(document_id)
    revision_params = Map.delete(params, "document_id")

    with {:ok, revision} <- Utils.module(:documents).create_revision(document, revision_params) do
      conn
      |> put_status(:created)
      |> render(:show, revision: revision)
    end
  end

  @doc """
  Turns the chosen proposals into a revision.

  One call, three things, one transaction: the revision is written, the
  annotations named as settled are resolved against it, and the proposals it
  used are accepted. Commit is the only moment at which someone has both
  decided and changed the document, so it is the only natural place for an
  annotation to be resolved.

  A block with an undecided contention is refused, but only that block: the
  rest of the selection goes through.
  """
  def commit(conn, %{"document_id" => document_id} = params) do
    document = get_document!(document_id)
    attrs = Map.delete(params, "document_id")

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
