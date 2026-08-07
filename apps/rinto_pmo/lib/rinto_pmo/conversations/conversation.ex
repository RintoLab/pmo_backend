defmodule RintoPMO.Conversations.Conversation do
  @moduledoc """
  One topic: the *process* of a collaborative review, as opposed to the
  conclusions it produces.

  A conversation deliberately hangs off nothing. It carries no `document_id`
  and no `annotation_id`, because a topic like "compare 《A》 and 《B》" spans
  two documents and belongs to neither. What it touches is derived from the
  refs on its messages, which also records *when* each thing was pulled into
  context -- something a join table would throw away.

  `pi_session_id` is the hot/cold marker. Non-nil and with a live process, the
  topic is hot: a pi process is carrying it. Otherwise it is cold and only the
  rows here remain, which is exactly enough to rebuild it. Topics are
  unlimited; pi processes are not.
  """

  use RintoPMO, :schema

  alias RintoPMO.Actors.Actor
  alias RintoPMO.Conversations.Message

  @type t :: %__MODULE__{}

  schema "conversations" do
    field :title, :string
    field :pi_session_id, :string
    field :replay_pending, :boolean, default: false

    belongs_to :actor, Actor
    belongs_to :assistant_actor, Actor

    has_many :messages, Message, preload_order: [asc: :position]

    timestamps()
  end

  @doc false
  def changeset(%__MODULE__{} = conversation \\ %__MODULE__{}, attrs) do
    conversation
    |> cast(attrs, [:title, :actor_id, :assistant_actor_id])
    |> validate_length(:title, max: 255)
    |> foreign_key_constraint(:actor_id)
    |> foreign_key_constraint(:assistant_actor_id)
  end

  @doc false
  def update_changeset(%__MODULE__{} = conversation, attrs) do
    conversation
    |> cast(attrs, [:title, :assistant_actor_id])
    |> validate_length(:title, max: 255)
    |> foreign_key_constraint(:assistant_actor_id)
  end

  @doc false
  def session_changeset(%__MODULE__{} = conversation, pi_session_id) do
    conversation
    |> change()
    |> put_change(:pi_session_id, pi_session_id)
    # A fresh pi process starts empty, so the next prompt owes it the recent
    # turns. Cooling clears the flag with the session: there is no process left
    # to owe anything to.
    |> put_change(:replay_pending, pi_session_id != nil)
    |> unique_constraint(:pi_session_id)
  end
end
