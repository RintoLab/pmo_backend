defmodule RintoPMO.Search.Searchable do
  @moduledoc """
  One resource projected into the shape discovery works on.

  ## Why a projection at all

  The things worth finding live in eight tables that disagree about everything:
  a document's title is on its latest revision, a task's is a column, a block
  has no title and only a body, a project is keyed by slug. Searching across
  them directly would be a union that has to be rewritten every time a resource
  type is added.

  Projecting once, on write, turns discovery into one query over one shape.

  ## A block is its own row

  Not folded into its document's. A block is independently addressable --
  `rinto://block/{id}` -- so it is independently findable, and a hit lands on
  the section that says the thing rather than on a document that mentions it
  somewhere. The document is reachable from the row (`document_id`) without a
  second lookup, which is the same second level the resolver and backlinks hand
  back.

  ## What is deliberately not projected

  A conversation contributes its **title only**. A topic is a transcript, and
  half of one returned as a search hit reads as a conclusion -- the same reason
  a conversation is linkable but never expandable.

  A proposal is not projected at all. It is reached through the document it is
  proposed against, so offering it as an independent hit would be a destination
  nobody navigates to directly.

  ## What retrieval over this looks like

  Semantic: an embedding of the query against `embedding` on each row. There is
  no lexical index, because the one thing that would earn one is a person
  half-typing a title and expecting a prefix match, and nobody in this system
  does that -- bodies are written by a model, which gets a `rinto://` URI back
  from its search tool and pastes it.

  ## `embedding` is null exactly when one is needed

  That is the whole of the state, and the reason there is no `embedded_at`
  beside it: when a projection last changed is `updated_at`, and the only thing
  a worker has to ask is whether there is a vector or not.

  It follows that **a rewrite must not blindly clear it.** Only the text that
  gets embedded -- `title` and `body` -- invalidates a vector. Re-projecting
  because a task was archived, or because everything was rebuilt, changes
  neither, and clearing the column there would send the whole corpus back
  through the embedding service for nothing. See `RintoPMO.Search.sync/4`.

  A row waiting for its vector is not findable at all, since there is no
  lexical path to fall back to. That is accepted -- whoever just wrote the
  thing is holding its id already -- but it does mean the gap between writing
  and embedding is a gap in discovery, so the worker is meant to run promptly
  rather than eventually.

  ## Still an index, not a truth

  Every row is derived from a resource, and rebuilding is how that claim stays
  checkable rather than merely asserted. Same standing as `RintoPMO.Links.Link`.
  """

  use RintoPMO, :schema

  @type t :: %__MODULE__{}

  schema "searchables" do
    field :resource_type, :string
    field :resource_id, UUIDv7

    field :title, :string
    field :body, :string

    # The filter that matters first. Finding the right thing is usually a
    # matter of looking in the right place, which is why scope is a column
    # rather than something to be inferred from the text.
    field :project_id, UUIDv7

    # How a block hit reaches its document without a second call.
    field :document_id, UUIDv7

    # Carried rather than filtered out. Archiving is not deleting, and whether
    # archived things belong in a given list is the caller's decision.
    field :archived, :boolean, default: false

    # Null means "needs embedding". Never cast from a caller: it is written by
    # the worker that computes it, and cleared by `RintoPMO.Search.sync/4` when
    # the text it stood for changes.
    field :embedding, Pgvector.Ecto.Vector

    timestamps()
  end

  @fields [:resource_type, :resource_id, :title, :body, :project_id, :document_id, :archived]

  @doc false
  def changeset(%__MODULE__{} = searchable \\ %__MODULE__{}, attrs) do
    searchable
    |> cast(attrs, @fields)
    |> validate_required([:resource_type, :resource_id])
    |> unique_constraint([:resource_type, :resource_id])
  end
end
