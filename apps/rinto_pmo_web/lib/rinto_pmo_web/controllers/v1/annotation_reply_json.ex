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
      inserted_at: reply.inserted_at,
      updated_at: reply.updated_at
    }
  end
end
