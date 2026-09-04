defmodule RintoPMOWeb.V1.AnnotationReplyController do
  use RintoPMOWeb, :controller

  alias RintoPMO.Utils
  alias RintoPMOWeb.Plugs.ActorToken

  @doc """
  Writes a follow-up under a note.

  Credited to whoever is calling, unless the request names a topic --
  `conversation_id` makes it a model's reply, signed by the stand-in AI. The
  token still says who the caller is; the topic says the caller is writing on a
  model's behalf rather than their own.

  `actor_id` is never read from the body either way. Naming an author is the
  one thing about a reply nobody outside the server gets to say, because it is
  what a model would have to be able to do to sign somebody else's name to its
  own opinion.
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
