defmodule RintoPMO.Conversations.Behaviour do
  @moduledoc false

  alias RintoPMO.Conversations.Conversation
  alias RintoPMO.Conversations.Message

  @type filter :: %{optional(:actor_id) => UUIDv7.t()}

  @type message_opts :: %{
          optional(:after_position) => non_neg_integer(),
          optional(:limit) => pos_integer()
        }

  @callback list_conversations(filter()) :: [Conversation.t()]
  @callback get_conversation!(UUIDv7.t()) :: Conversation.t()
  @callback create_conversation(map()) ::
              {:ok, Conversation.t()} | {:error, Ecto.Changeset.t()}
  @callback update_conversation(Conversation.t(), map()) ::
              {:ok, Conversation.t()} | {:error, Ecto.Changeset.t()}

  @callback list_messages(Conversation.t(), message_opts()) :: [Message.t()]
  @callback recent_messages(Conversation.t(), pos_integer()) :: [Message.t()]
  @callback get_message!(Conversation.t(), UUIDv7.t()) :: Message.t()
  @callback append_message(Conversation.t(), map()) ::
              {:ok, Message.t()} | {:error, Ecto.Changeset.t()}

  @callback attach_session(Conversation.t(), String.t()) ::
              {:ok, Conversation.t()} | {:error, Ecto.Changeset.t()}
  @callback detach_session(Conversation.t()) ::
              {:ok, Conversation.t()} | {:error, Ecto.Changeset.t()}
  @callback get_conversation_by_session(String.t()) :: Conversation.t() | nil
  @callback claim_replay(Conversation.t()) :: boolean()

  @callback list_conversations_for_ref(String.t(), UUIDv7.t()) :: [Conversation.t()]
end
