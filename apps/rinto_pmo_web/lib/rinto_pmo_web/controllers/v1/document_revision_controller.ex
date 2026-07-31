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

  defp get_document!(document_id) do
    Utils.module(:documents).get_document!(document_id)
  end
end
