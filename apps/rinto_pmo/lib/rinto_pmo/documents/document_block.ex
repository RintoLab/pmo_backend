defmodule RintoPMO.Documents.DocumentBlock do
  @moduledoc """
  An immutable snapshot of one logical block in a document revision.

  `block_id` remains stable across revisions while the schema primary key
  identifies this particular snapshot.
  """

  use RintoPMO, :schema

  alias RintoPMO.Actors.Actor
  alias RintoPMO.Documents.DocumentRevision

  @type t :: %__MODULE__{}

  schema "document_blocks" do
    field :block_id, UUIDv7
    field :content, :string
    field :position, :integer

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
