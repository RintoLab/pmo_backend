defmodule RintoPMO.Annotations.Annotation do
  @moduledoc """
  A document annotation thread.

  Annotations hang off the stable document identity (not a revision). The first
  opinion lives in `content`; subsequent opinions are append-only replies with
  monotonic positions. Optional `block_id`, `block_text`, and `selected_text`
  capture anchor context without positional offsets inside a block.

  ## There is no status, only a mark somebody put here

  `confirmed_at` is null until a person says this thread is over, and that is
  the whole of it. It is not a workflow state and nothing derives one: no
  amount of discussion moves it, and nothing in this system decides on a
  person's behalf that their turn has come.

  It was three states once -- open, resolved, dismissed -- and two of those
  were the same answer carrying a reason. Which reason is already next to it:
  `confirmed_by_revision_id` names the change that settled this, and its
  absence is somebody deciding no change was needed. Spending a state on that
  said it twice.

  Only a person moves it, so it is kept out of `changeset/2` and
  `update_changeset/2` entirely and travels through `confirm_changeset/2` and
  `unconfirm_changeset/1` alone. Editing an annotation's wording must not be
  able to silently close it.

  `confirmed_by_revision_id` is meaningful only while `confirmed_at` is set;
  unconfirming clears both together.
  """

  use RintoPMO, :schema

  alias RintoPMO.Actors.Actor
  alias RintoPMO.Annotations.AnnotationReply
  alias RintoPMO.Documents.Document
  alias RintoPMO.Documents.DocumentRevision
  alias RintoPMO.Embeddings

  @type t :: %__MODULE__{}

  schema "annotations" do
    field :block_id, UUIDv7
    field :block_text, :string
    field :selected_text, :string
    field :content, :string
    field :confirmed_at, :utc_datetime_usec

    # Null means "needs embedding". Never cast from a caller: it is written
    # by the worker that computes it, and voided by whichever changeset rewrites
    # the content it was made from. See `RintoPMO.Embeddings`.
    field :embedding, Pgvector.Ecto.Vector

    belongs_to :document, Document
    belongs_to :actor, Actor
    belongs_to :confirmed_by_revision, DocumentRevision

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
  def confirm_changeset(%__MODULE__{} = annotation, attrs \\ %{}) do
    annotation
    |> cast(attrs, [:confirmed_by_revision_id])
    |> put_change(:confirmed_at, confirmed_at(annotation))
    |> foreign_key_constraint(:confirmed_by_revision_id)
  end

  @doc false
  def unconfirm_changeset(%__MODULE__{} = annotation) do
    annotation
    |> change()
    |> put_change(:confirmed_at, nil)
    |> put_change(:confirmed_by_revision_id, nil)
  end

  # Confirming an already-confirmed annotation leaves the original moment
  # alone. The mark records when somebody first said this was over, and a
  # second call -- naming the revision this time, say -- is not a second
  # ending. Reopening and confirming again *is*, and that clears it first.
  defp confirmed_at(%__MODULE__{confirmed_at: nil}), do: DateTime.utc_now()
  defp confirmed_at(%__MODULE__{confirmed_at: confirmed_at}), do: confirmed_at
end
