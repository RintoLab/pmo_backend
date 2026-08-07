defmodule RintoPMOWeb.V1.MessageJSON do
  alias RintoPMO.Conversations.Message
  alias RintoPMO.Conversations.MessageRef

  def index(%{messages: messages}) do
    %{data: Enum.map(messages, &data/1)}
  end

  def show(%{message: message}) do
    %{data: data(message)}
  end

  @doc false
  def data(%Message{} = message) do
    %{
      id: message.id,
      conversation_id: message.conversation_id,
      actor_id: message.actor_id,
      role: message.role,
      content: message.content,
      position: message.position,
      refs: refs(message),
      inserted_at: message.inserted_at,
      updated_at: message.updated_at
    }
  end

  defp refs(%Message{refs: refs}) when is_list(refs), do: Enum.map(refs, &ref/1)
  defp refs(%Message{}), do: []

  defp ref(%MessageRef{} = ref) do
    %{
      id: ref.id,
      ref_type: ref.ref_type,
      # The order the refs were given in, which is the order they expand into
      # the prelude, and so part of what a replay reproduces.
      position: ref.position,
      ref_id: ref.ref_id,
      ref_document_id: ref.ref_document_id,
      # The client's own ref map, byte for byte. This is what a caller replays.
      payload: ref.payload
    }
  end
end
