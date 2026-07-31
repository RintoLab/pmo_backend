defmodule RintoPMO.Annotations.AnnotationReply do
  @moduledoc """
  A follow-up opinion on an annotation.

  Replies are a single flat list under an annotation (no reply-to-reply tree).
  `position` increases monotonically; deletions leave gaps and never renumber.
  """

  use RintoPMO, :schema

  alias RintoPMO.Actors.Actor
  alias RintoPMO.Annotations.Annotation

  @type t :: %__MODULE__{}

  schema "annotation_replies" do
    field :content, :string
    field :position, :integer

    belongs_to :annotation, Annotation
    belongs_to :actor, Actor

    timestamps()
  end

  @doc false
  def changeset(%__MODULE__{} = reply \\ %__MODULE__{}, attrs) do
    reply
    |> cast(attrs, [:annotation_id, :actor_id, :content, :position])
    |> validate_required([:annotation_id, :actor_id, :content, :position])
    |> validate_number(:position, greater_than_or_equal_to: 0)
    |> foreign_key_constraint(:annotation_id)
    |> foreign_key_constraint(:actor_id)
    |> unique_constraint(:position, name: :annotation_replies_annotation_id_position_index)
  end

  @doc false
  def update_changeset(%__MODULE__{} = reply, attrs) do
    reply
    |> cast(attrs, [:content])
    |> validate_required([:content])
  end
end
