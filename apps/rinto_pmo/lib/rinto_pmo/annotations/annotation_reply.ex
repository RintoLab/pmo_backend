defmodule RintoPMO.Annotations.AnnotationReply do
  @moduledoc """
  A follow-up opinion on an annotation.

  Replies are a single flat list under an annotation (no reply-to-reply tree).
  `position` increases monotonically; deletions leave gaps and never renumber.

  A reply carries an *opinion*, never chat transcript. Two kinds of author
  write them and `actor_id` is how they are told apart: a person, and the AI
  that somebody asked to answer this one annotation
  (`RintoPMO.Annotations.request_reply/1`).

  Conversations do not write here at all. A topic is where proposals come
  from; what it concluded lands in the document, not on the note that started
  it. There was once a `source_message_id` pointing back at a message, and
  nothing wrote it -- see the migration that dropped it.
  """

  use RintoPMO, :schema

  alias RintoPMO.Actors.Actor
  alias RintoPMO.Annotations.Annotation
  alias RintoPMO.Embeddings

  @type t :: %__MODULE__{}

  schema "annotation_replies" do
    field :content, :string
    field :position, :integer

    # Null means "needs embedding". Never cast from a caller: it is written
    # by the worker that computes it, and voided by whichever changeset rewrites
    # the content it was made from. See `RintoPMO.Embeddings`.
    field :embedding, Pgvector.Ecto.Vector

    belongs_to :annotation, Annotation
    belongs_to :actor, Actor

    timestamps()
  end

  @doc false
  def changeset(%__MODULE__{} = reply \\ %__MODULE__{}, attrs) do
    reply
    |> cast(attrs, [:annotation_id, :actor_id, :content, :position])
    |> validate_required([:annotation_id, :actor_id, :content, :position])
    |> validate_length(:content, min: 1)
    |> validate_number(:position, greater_than_or_equal_to: 0)
    |> foreign_key_constraint(:annotation_id)
    |> foreign_key_constraint(:actor_id)
    |> unique_constraint(:position, name: :annotation_replies_annotation_id_position_index)
    |> Embeddings.invalidate([:content])
  end

  @doc false
  def update_changeset(%__MODULE__{} = reply, attrs) do
    reply
    |> cast(attrs, [:content])
    |> validate_required([:content])
    |> validate_length(:content, min: 1)
    |> Embeddings.invalidate([:content])
  end
end
