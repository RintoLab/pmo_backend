defmodule RintoPMO.Annotations.Annotation do
  @moduledoc """
  A document annotation thread.

  Annotations hang off the stable document identity (not a revision). The first
  opinion lives in `content`; subsequent opinions are append-only replies with
  monotonic positions. Optional `block_id`, `block_text`, and `selected_text`
  capture anchor context without positional offsets inside a block.
  """

  use RintoPMO, :schema

  alias RintoPMO.Actors.Actor
  alias RintoPMO.Annotations.AnnotationReply
  alias RintoPMO.Documents.Document

  @type t :: %__MODULE__{}

  schema "annotations" do
    field :block_id, UUIDv7
    field :block_text, :string
    field :selected_text, :string
    field :content, :string

    belongs_to :document, Document
    belongs_to :actor, Actor

    has_many :replies, AnnotationReply, preload_order: [asc: :position]

    timestamps()
  end

  @doc false
  def changeset(%__MODULE__{} = annotation \\ %__MODULE__{}, attrs) do
    annotation
    |> cast(attrs, [
      :document_id,
      :actor_id,
      :block_id,
      :block_text,
      :selected_text,
      :content
    ])
    |> validate_required([:document_id, :actor_id, :content])
    |> validate_length(:content, min: 1)
    |> foreign_key_constraint(:document_id)
    |> foreign_key_constraint(:actor_id)
  end

  @doc false
  def update_changeset(%__MODULE__{} = annotation, attrs) do
    annotation
    |> cast(attrs, [:content, :block_id, :block_text, :selected_text])
    |> validate_required([:content])
    |> validate_length(:content, min: 1)
  end
end
