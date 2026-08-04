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
  """

  use RintoPMO, :schema

  alias RintoPMO.Actors.Actor
  alias RintoPMO.Annotations.AnnotationReply
  alias RintoPMO.Documents.Document
  alias RintoPMO.Documents.DocumentRevision

  @type t :: %__MODULE__{}
  @type status :: :open | :resolved | :dismissed

  @statuses [:open, :resolved, :dismissed]

  schema "annotations" do
    field :block_id, UUIDv7
    field :block_text, :string
    field :selected_text, :string
    field :content, :string
    field :status, Ecto.Enum, values: @statuses, default: :open

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
  end

  @doc false
  def update_changeset(%__MODULE__{} = annotation, attrs) do
    annotation
    |> cast(attrs, [:content, :block_id, :block_text, :selected_text])
    |> validate_required([:content])
    |> validate_length(:content, min: 1)
  end

  @doc false
  def status_changeset(annotation, status, attrs \\ %{})

  def status_changeset(%__MODULE__{} = annotation, :resolved, attrs) do
    annotation
    |> cast(attrs, [:resolved_by_revision_id])
    |> put_change(:status, :resolved)
    |> foreign_key_constraint(:resolved_by_revision_id)
  end

  def status_changeset(%__MODULE__{} = annotation, :dismissed, _attrs) do
    annotation
    |> change()
    |> put_change(:status, :dismissed)
  end

  def status_changeset(%__MODULE__{} = annotation, :open, _attrs) do
    # Reopening drops the pointer as well: it named the revision that settled
    # this annotation, and nothing settles it any more.
    annotation
    |> change()
    |> put_change(:status, :open)
    |> put_change(:resolved_by_revision_id, nil)
  end
end
