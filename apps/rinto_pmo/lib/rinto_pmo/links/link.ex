defmodule RintoPMO.Links.Link do
  @moduledoc """
  One `rinto://` reference, indexed out of the body that wrote it.

  ## This is an index, not a truth

  Every row here is derivable from the text it was read out of. Drop the whole
  table and `mix rinto.index.rebuild` puts it back. That is not a disclaimer --
  it is what lets the rest of the design be simple: no foreign keys to maintain,
  no cascade to reason about, and a missed cleanup that costs a stale row rather
  than a corrupt system.

  It does not contradict "relationships are derived, there is no join table"
  (`docs/api-frontend-guide.md`). What that refuses is a hand-maintained table
  of relationships people declare. This is a materialised view of relationships
  the text already states. A purely derived answer would mean scanning every
  body in the system to find out who mentions one task.

  ## No foreign keys

  Targets are polymorphic, so there is nothing single to point at. More to the
  point, **a reference has to outlive its target**: a link to a deleted task is
  reported as broken, which is the whole reason to keep it. A foreign key would
  make the useful case impossible.

  Source rows are therefore cleaned up explicitly, by `RintoPMO.Links.purge/3`
  and by the delete-and-reinsert in `sync_document/2`.

  ## Not deduplicated

  A block citing one task twice is two rows with different `position`s. Same
  reason `RintoPMO.Conversations.MessageRef` does not dedupe: collapsing them
  would renumber positions and lose which mention was which.

  ## Only the latest revision

  Block rows are per-revision snapshots that never go away, but only the latest
  revision's are indexed. Indexing all of them would answer "who points at this"
  with every historical draft that ever did -- and "who used to point at this"
  is a different question, not one to fold into the default. Because only the
  latest is here, "delete this document's block rows and reinsert" is the
  correct way to follow a body, rather than a blunt one.

  ## `target_document_id` is resolved, not addressed

  `rinto://block/{id}` carries no document, because a URI stays one shape for
  every type. The document is looked up when the row is written and stored here,
  which is what keeps "who points into this document" a single indexed query.
  `RintoPMO.Conversations.MessageRef` does the same with a project slug: the
  address stays as authored, the index stores what it resolved to.
  """

  use RintoPMO, :schema

  @type t :: %__MODULE__{}

  schema "links" do
    # Neither is an `Ecto.Enum` nor constrained in the database: both sets grow
    # with the system, and text written today must not stop loading because a
    # later build learned a new kind of thing.
    field :source_type, :string
    field :source_id, UUIDv7
    field :source_document_id, UUIDv7

    field :target_type, :string
    field :target_id, UUIDv7
    field :target_slug, :string
    field :target_document_id, UUIDv7

    field :label, :string
    field :position, :integer

    timestamps(updated_at: false)
  end

  @fields [
    :source_type,
    :source_id,
    :source_document_id,
    :target_type,
    :target_id,
    :target_slug,
    :target_document_id,
    :label,
    :position
  ]

  @doc false
  def changeset(%__MODULE__{} = link \\ %__MODULE__{}, attrs) do
    link
    |> cast(attrs, @fields)
    |> validate_required([:source_type, :source_id, :target_type, :label, :position])
  end
end
