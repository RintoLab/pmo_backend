defmodule RintoPMOWeb.V1.AnnotationReplyController do
  use RintoPMOWeb, :controller

  alias RintoPMO.Utils
  alias RintoPMOWeb.Plugs.ActorToken

  @doc """
  Writes a follow-up under a note, credited to whoever is calling.

  The same rule the note itself follows: a person writes here, and the AI's
  replies are written by `annotation_actor` through `RintoPMO.Annotations`,
  never over HTTP.
  """
  def create(conn, %{"document_id" => document_id, "annotation_id" => annotation_id} = params) do
    context = annotations_context()
    annotation = get_annotation!(document_id, annotation_id)

    attrs =
      params
      |> Map.drop(["document_id", "annotation_id"])
      |> Map.put("actor_id", ActorToken.current_actor!(conn).id)

    with {:ok, reply} <- context.create_reply(annotation, attrs) do
      conn
      |> put_status(:created)
      |> render(:show, reply: reply)
    end
  end

  def update(
        conn,
        %{
          "document_id" => document_id,
          "annotation_id" => annotation_id,
          "reply_id" => reply_id
        } = params
      ) do
    context = annotations_context()
    annotation = get_annotation!(document_id, annotation_id)
    reply = context.get_reply!(annotation, reply_id)
    attrs = Map.drop(params, ["document_id", "annotation_id", "reply_id"])

    with {:ok, reply} <- context.update_reply(reply, attrs) do
      render(conn, :show, reply: reply)
    end
  end

  def delete(conn, %{
        "document_id" => document_id,
        "annotation_id" => annotation_id,
        "reply_id" => reply_id
      }) do
    context = annotations_context()
    annotation = get_annotation!(document_id, annotation_id)
    reply = context.get_reply!(annotation, reply_id)

    with {:ok, _reply} <- context.delete_reply(reply) do
      send_resp(conn, :no_content, "")
    end
  end

  defp get_annotation!(document_id, annotation_id) do
    document = Utils.module(:documents).get_document!(document_id)
    annotations_context().get_annotation!(document, annotation_id)
  end

  defp annotations_context, do: Utils.module(:annotations)
end
