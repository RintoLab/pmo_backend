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

  ## Who named it

  `title_source` records that, and exists so the auto-namer can never take
  something back from a person:

      title  source   meaning
      ----   ------   -------
      nil    nil      unnamed, and `RintoPMO.Conversations.Titles` may name it
      set    :auto    named by the model (or its fallback)
      set    :manual  named by a person
      nil    :manual  a person cleared the name, and meant it

  The last row is why clearing a title is not the same as never having had
  one: without the marker, the next message would helpfully name the topic
  again and the person would have to clear it forever.
  """

  use RintoPMO, :schema

  alias RintoPMO.Actors.Actor
  alias RintoPMO.Conversations.Message

  @type t :: %__MODULE__{}

  schema "conversations" do
    field :title, :string
    field :title_source, Ecto.Enum, values: [:auto, :manual]
    field :title_generated_at, :utc_datetime_usec
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
    # A title given at creation is somebody's choice of words. Being created
    # without one is not a choice, so it stays eligible for auto-naming.
    |> put_title_source(named?(attrs))
    |> foreign_key_constraint(:actor_id)
    |> foreign_key_constraint(:assistant_actor_id)
  end

  @doc false
  def update_changeset(%__MODULE__{} = conversation, attrs) do
    conversation
    |> cast(attrs, [:title, :assistant_actor_id])
    |> blank_title_to_nil()
    |> validate_length(:title, max: 255)
    # Mentioning `title` at all is a person naming the topic -- including
    # naming it nothing. Either way the auto-namer stops considering it.
    |> put_title_source(title_given?(attrs))
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

  defp put_title_source(changeset, false), do: changeset

  defp put_title_source(changeset, true) do
    changeset
    |> put_change(:title_source, :manual)
    |> put_change(:title_generated_at, nil)
  end

  defp blank_title_to_nil(changeset) do
    case get_change(changeset, :title) do
      title when is_binary(title) ->
        if String.trim(title) == "", do: put_change(changeset, :title, nil), else: changeset

      _absent_or_nil ->
        changeset
    end
  end

  defp title_given?(attrs), do: Map.has_key?(attrs, :title) or Map.has_key?(attrs, "title")

  defp named?(attrs) do
    case Map.get(attrs, :title) || Map.get(attrs, "title") do
      title when is_binary(title) -> String.trim(title) != ""
      _absent_or_nil -> false
    end
  end
end
