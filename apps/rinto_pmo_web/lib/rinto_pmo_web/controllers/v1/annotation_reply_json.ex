defmodule RintoPMOWeb.V1.AnnotationReplyJSON do
  alias RintoPMO.Annotations.AnnotationReply

  def show(%{reply: reply}) do
    %{data: data(reply)}
  end

  def data(%AnnotationReply{} = reply) do
    %{
      id: reply.id,
      annotation_id: reply.annotation_id,
      actor_id: reply.actor_id,
      content: reply.content,
      position: reply.position,
      # Present when this conclusion came out of a topic; it is what the UI
      # links back to so a reader can see the discussion behind it.
      source_message_id: reply.source_message_id,
      inserted_at: reply.inserted_at,
      updated_at: reply.updated_at
    }
  end
end
