defmodule RintoPMOWeb.V1.AttachmentController do
  @moduledoc """
  Image uploads for chat references.

  Upload is `multipart/form-data` rather than base64 JSON on purpose: base64 is
  a third larger, and the bytes would have to be decoded before anything could
  be checked. Multipart lets Plug stream to a temp file, which the context then
  stats before reading, so an oversize upload is refused without being pulled
  into memory.

  `GET /attachments/:id/content` exists for the client, not the agent: after a
  reload the chat has ids but no bytes, and a referenced image still has to
  render in the transcript.
  """

  use RintoPMOWeb, :controller

  alias Plug.Upload
  alias RintoPMO.Utils

  def create(conn, %{"actor_id" => actor_id, "file" => %Upload{} = upload}) do
    attrs = %{
      "actor_id" => actor_id,
      "filename" => upload.filename,
      "path" => upload.path
    }

    with {:ok, attachment} <- attachments().create_attachment(attrs) do
      conn
      |> put_status(:created)
      |> render(:show, attachment: attachment)
    end
  end

  def create(_conn, _params) do
    {:error, :bad_request, %{"file" => ["is required"], "actor_id" => ["is required"]}}
  end

  def show(conn, %{"id" => id}) do
    render(conn, :show, attachment: attachments().get_attachment!(id))
  end

  def content(conn, %{"id" => id}) do
    attachment = attachments().get_attachment!(id)

    with {:ok, bytes} <- attachments().read_attachment(attachment) do
      conn
      |> put_resp_content_type(attachment.mime_type)
      |> put_resp_header("content-disposition", disposition(attachment))
      |> send_resp(:ok, bytes)
    end
  end

  def delete(conn, %{"id" => id}) do
    attachment = attachments().get_attachment!(id)

    with {:ok, _attachment} <- attachments().delete_attachment(attachment) do
      send_resp(conn, :no_content, "")
    end
  end

  # `inline` so a browser renders it in an <img> instead of downloading it, with
  # the original name kept for a deliberate save.
  defp disposition(%{filename: nil}), do: "inline"

  defp disposition(%{filename: filename}) do
    ~s(inline; filename="#{String.replace(filename, "\"", "")}")
  end

  defp attachments, do: Utils.module(:attachments)
end
