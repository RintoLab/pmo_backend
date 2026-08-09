defmodule RintoPMOWeb.V1.ConversationJSON do
  alias RintoPMO.Conversations.Conversation
  alias RintoPMO.Conversations.Sessions

  def index(%{conversations: conversations}) do
    %{data: Enum.map(conversations, &data/1)}
  end

  def show(%{conversation: conversation}) do
    %{data: data(conversation)}
  end

  @doc false
  def data(%Conversation{} = conversation) do
    %{
      id: conversation.id,
      title: conversation.title,
      # Who named it: `manual` is a person's words and is never overwritten,
      # `auto` is the system's guess, `null` means nobody has yet. A client
      # showing "未命名话题" can tell "not named yet" from "named nothing".
      title_source: conversation.title_source,
      actor_id: conversation.actor_id,
      # Whose replies these are. A property of the topic, not of each message.
      assistant_actor_id: conversation.assistant_actor_id,
      pi_session_id: conversation.pi_session_id,
      # Derived rather than stored: a pi session can die without anything
      # getting a chance to clear the column, so a non-null pi_session_id is a
      # claim and this is the check of it.
      hot: Sessions.hot?(conversation),
      replay_pending: conversation.replay_pending,
      inserted_at: conversation.inserted_at,
      updated_at: conversation.updated_at
    }
  end
end
