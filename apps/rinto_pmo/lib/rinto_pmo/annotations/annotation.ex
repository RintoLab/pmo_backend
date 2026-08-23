defmodule RintoPMO.Annotations.Annotation do
  @moduledoc """
  A document annotation thread.

  Annotations hang off the stable document identity (not a revision). The first
  opinion lives in `content`; subsequent opinions are append-only replies with
  monotonic positions. Optional `block_id`, `block_text`, and `selected_text`
  capture anchor context without positional offsets inside a block.

  `status` is what lets collaborative review converge: without it there is no
  way to say "the AI is done talking, a human still has to decide". Only a
  human decision moves it — being discussed changes nothing — so it is kept out
  of `changeset/2` and `update_changeset/2` entirely and can only travel through
  `status_changeset/3`. Editing an annotation's wording must not be able to
  silently close it.

  `resolved_by_revision_id` is meaningful only while `status` is `:resolved`;
  every other transition clears it.
  """

  use RintoPMO, :schema

  alias RintoPMO.Actors.Actor
  alias RintoPMO.Annotations.AnnotationReply
  alias RintoPMO.Documents.Document
  alias RintoPMO.Documents.DocumentRevision
  alias RintoPMO.Embeddings

  @type t :: %__MODULE__{}
  @type status :: :open | :resolved | :dismissed

  @statuses [:open, :resolved, :dismissed]

  schema "annotations" do
    field :block_id, UUIDv7
    field :block_text, :string
    field :selected_text, :string
    field :content, :string
    field :status, Ecto.Enum, values: @statuses, default: :open

    # Null means "needs embedding". Never cast from a caller: it is written
    # by the worker that computes it, and voided by whichever changeset rewrites
    # the content it was made from. See `RintoPMO.Embeddings`.
    field :embedding, Pgvector.Ecto.Vector

    belongs_to :document, Document
    belongs_to :actor, Actor
    belongs_to :resolved_by_revision, DocumentRevision

    has_many :replies, AnnotationReply, preload_order: [asc: :position]

    timestamps()
  end

  @doc """
  The statuses an annotation can hold.
  """
  @spec statuses() :: [status()]
  def statuses, do: @statuses

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
    |> Embeddings.invalidate([:content])
  end

  @doc false
  def update_changeset(%__MODULE__{} = annotation, attrs) do
    annotation
    |> cast(attrs, [:content, :block_id, :block_text, :selected_text])
    |> validate_required([:content])
    |> validate_length(:content, min: 1)
    |> Embeddings.invalidate([:content])
  end

  @doc false
  def status_changeset(annotation, status, attrs \\ %{})

  def status_changeset(%__MODULE__{} = annotation, :resolved, attrs) do
    annotation
    |> cast(attrs, [:resolved_by_revision_id])
    |> put_change(:status, :resolved)
    |> foreign_key_constraint(:resolved_by_revision_id)
  end

  # Everything other than `:resolved` drops the pointer, because only
  # `:resolved` can honestly carry one: it names the revision that settled this
  # annotation. Reopening means nothing settles it any more, and dismissing
  # means it was declined without the document changing at all -- in both cases
  # a revision left there would be a claim that never happened.
  def status_changeset(%__MODULE__{} = annotation, status, _attrs)
      when status in [:open, :dismissed] do
    annotation
    |> change()
    |> put_change(:status, status)
    |> put_change(:resolved_by_revision_id, nil)
  end
end
