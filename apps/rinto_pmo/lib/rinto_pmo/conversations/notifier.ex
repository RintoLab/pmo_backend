defmodule RintoPMO.Conversations.Notifier do
  @moduledoc """
  Says that a topic's own row changed, to everyone watching the topic.

  Messages already reach a client through the pi session carrying the
  conversation, which is fine while there is one. The conversation row changes
  at moments when there may not be: a title arrives from a background job long
  after -- or instead of -- an answer. So this is broadcast on the
  conversation, not on the session, and reaches every subscriber rather than
  the connection that happened to start the work.
  """

  alias RintoPMO.Conversations.Conversation

  @pubsub RintoPMO.PubSub

  @doc """
  The PubSub topic carrying one conversation's row changes.

  Deliberately equal to the channel topic clients already join, so there is one
  name for "this topic" rather than two that have to be kept in step.
  """
  @spec topic(UUIDv7.t()) :: String.t()
  def topic(conversation_id) when is_binary(conversation_id),
    do: "conversation:" <> conversation_id

  @doc """
  Subscribes the calling process to a conversation's row changes.
  """
  @spec subscribe(UUIDv7.t(), atom()) :: :ok | {:error, term()}
  def subscribe(conversation_id, pubsub \\ @pubsub) do
    Phoenix.PubSub.subscribe(pubsub, topic(conversation_id))
  end

  @doc """
  Announces the current state of a conversation row.

  The whole conversation is sent rather than the field that changed: a
  subscriber renders the topic, and giving it everything means a new field
  never needs a new message.
  """
  @spec broadcast_updated(Conversation.t(), atom()) :: :ok | {:error, term()}
  def broadcast_updated(%Conversation{} = conversation, pubsub \\ @pubsub) do
    Phoenix.PubSub.broadcast(
      pubsub,
      topic(conversation.id),
      {:conversation_updated, conversation}
    )
  end
end
