defmodule RintoPMO.Documents.DocumentRevision do
  @moduledoc """
  An immutable commit in a document's linear revision history.
  """

  use RintoPMO, :schema

  alias RintoPMO.Documents.Document
  alias RintoPMO.Documents.DocumentBlock

  @type t :: %__MODULE__{}

  schema "document_revisions" do
    field :title, :string
    field :change_summary, :string
    field :base_revision_id, UUIDv7, virtual: true

    belongs_to :document, Document
    belongs_to :parent, __MODULE__

    has_many :blocks, DocumentBlock,
      foreign_key: :revision_id,
      preload_order: [asc: :position]

    timestamps(updated_at: false)
  end

  @doc false
  def initial_changeset(%__MODULE__{} = revision, attrs) do
    revision
    |> cast(attrs, [:title, :change_summary])
    |> validate_required([:title])
    |> foreign_key_constraint(:document_id)
    |> cast_assoc(:blocks, with: &DocumentBlock.initial_changeset/2)
    |> assign_block_positions()
  end

  @doc false
  def next_changeset(%__MODULE__{} = revision, %__MODULE__{} = parent, attrs) do
    revision
    |> cast(attrs, [:title, :change_summary, :base_revision_id])
    |> inherit_title(parent, attrs)
    |> validate_required([:title, :base_revision_id])
    |> foreign_key_constraint(:document_id)
    |> foreign_key_constraint(:parent_id)
    |> unique_constraint(:parent_id)
    |> check_constraint(:parent_id, name: :document_revisions_parent_differs_from_id)
  end

  defp inherit_title(changeset, parent, attrs) do
    if attr_present?(attrs, :title) do
      changeset
    else
      put_change(changeset, :title, parent.title)
    end
  end

  defp assign_block_positions(changeset) do
    case get_change(changeset, :blocks) do
      nil ->
        changeset

      block_changesets when is_list(block_changesets) ->
        block_changesets =
          block_changesets
          |> Enum.with_index()
          |> Enum.map(fn {block_changeset, position} ->
            put_change(block_changeset, :position, position)
          end)

        put_change(changeset, :blocks, block_changesets)
    end
  end

  defp attr_present?(attrs, key) do
    Map.has_key?(attrs, key) or Map.has_key?(attrs, Atom.to_string(key))
  end
end
