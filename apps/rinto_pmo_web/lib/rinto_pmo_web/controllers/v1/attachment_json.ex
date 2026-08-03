defmodule RintoPMOWeb.V1.AttachmentJSON do
  alias RintoPMO.Attachments.Attachment

  def show(%{attachment: attachment}) do
    %{data: data(attachment)}
  end

  @doc false
  def data(%Attachment{} = attachment) do
    %{
      id: attachment.id,
      actor_id: attachment.actor_id,
      filename: attachment.filename,
      mime_type: attachment.mime_type,
      byte_size: attachment.byte_size,
      width: attachment.width,
      height: attachment.height,
      checksum: attachment.checksum,
      inserted_at: attachment.inserted_at,
      last_used_at: attachment.last_used_at
    }
  end
end
