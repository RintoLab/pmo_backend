defmodule RintoPMO.Conversations.Message do
  @moduledoc """
  One turn in a conversation.

  Turn-level, never frame-level: `message_update` is a high-frequency delta
  stream and storing it would buy nothing, so a message is written once, when
  pi reports the message complete.

  `content` is the raw text -- what the human typed, or what the model said --
  and never the prelude `RintoPMO.Agent.PromptBuilder` assembles from the refs.
  The refs are stored beside it instead, so replay re-expands them against the
  documents as they stand at replay time. Storing the expanded prelude would
  feed a stale snapshot back to the model weeks later.

  `role` is kept even when `actor.kind` implies it: replay needs what pi was
  given, not our attribution of who gave it. A plain-chat assistant turn has no
  actor at all, and snapshots the provider, model and thinking level that
  produced it instead. User turns always retain their human actor.
  """

  use RintoPMO, :schema

  alias RintoPMO.Actors.Actor
  alias RintoPMO.Conversations.Conversation
  alias RintoPMO.Conversations.MessageRef

  @type t :: %__MODULE__{}
  @type role :: :user | :assistant

  @roles [:user, :assistant]

  schema "messages" do
    field :role, Ecto.Enum, values: @roles
    field :content, :string
    field :position, :integer
    field :provider, :string
    field :model, :string
    field :thinking_level, :string

    belongs_to :conversation, Conversation
    belongs_to :actor, Actor

    has_many :refs, MessageRef, preload_order: [asc: :position]

    timestamps()
  end

  @doc """
  The roles a message can hold.
  """
  @spec roles() :: [role()]
  def roles, do: @roles

  @doc false
  def changeset(%__MODULE__{} = message \\ %__MODULE__{}, attrs) do
    message
    |> cast(attrs, [
      :conversation_id,
      :actor_id,
      :role,
      :content,
      :position,
      :provider,
      :model,
      :thinking_level
    ])
    |> validate_required([:conversation_id, :role, :content, :position])
    |> require_user_actor()
    |> validate_length(:content, min: 1)
    |> validate_number(:position, greater_than_or_equal_to: 0)
    |> foreign_key_constraint(:conversation_id)
    |> foreign_key_constraint(:actor_id)
    |> unique_constraint([:conversation_id, :position])
    |> check_constraint(:actor_id, name: :messages_user_actor_required)
  end

  defp require_user_actor(changeset) do
    if get_field(changeset, :role) == :user do
      validate_required(changeset, [:actor_id])
    else
      changeset
    end
  end
end
