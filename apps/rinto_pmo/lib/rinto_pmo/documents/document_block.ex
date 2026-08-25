defmodule RintoPMO.Documents.DocumentBlock do
  @moduledoc """
  An immutable snapshot of one logical block in a document revision.

  `block_id` remains stable across revisions while the schema primary key
  identifies this particular snapshot.

  ## The vector belongs to the snapshot, not to the block

  `embedding` describes *this* row's `content`. A new revision writes a new row
  for every block, and one whose content is unchanged has its vector carried
  onto the new row -- see `RintoPMO.Documents.put_block_snapshots/3`. A row for
  content that changed starts null, which is the whole of "this needs
  embedding".

  Superseded rows have theirs cleared as the next revision lands, so exactly
  one snapshot of each block carries a vector: the current one. History is not
  searched, and keeping four kilobytes per row to answer nothing is not worth
  the storage.

  Never cast from a caller.
  """

  use RintoPMO, :schema

  alias RintoPMO.Actors.Actor
  alias RintoPMO.Documents.DocumentRevision

  @type t :: %__MODULE__{}

  schema "document_blocks" do
    field :block_id, UUIDv7
    field :content, :string
    field :position, :integer
    field :embedding, Pgvector.Ecto.Vector

    belongs_to :revision, DocumentRevision
    belongs_to :actor, Actor
  end

  @doc false
  def initial_changeset(%__MODULE__{} = block, attrs) do
    block
    |> cast(attrs, [:actor_id, :content])
    |> put_change(:block_id, UUIDv7.generate())
    |> validate_block()
  end

  @doc false
  def changeset(%__MODULE__{} = block, attrs) do
    block
    |> cast(attrs, [:actor_id, :content])
    |> validate_block()
  end

  defp validate_block(changeset) do
    changeset
    |> validate_required([:actor_id, :content])
    |> foreign_key_constraint(:revision_id)
    |> foreign_key_constraint(:actor_id)
    |> unique_constraint(:block_id, name: :document_blocks_revision_id_block_id_index)
    |> unique_constraint(:position, name: :document_blocks_revision_id_position_index)
    |> check_constraint(:position, name: :document_blocks_position_non_negative)
  end
end
