defmodule RintoPMO.Documents.BlockEmbedding do
  @moduledoc """
  A block's findable text and the vector made from it.

  The only resource in this system whose embedding does not live on its own
  row, and the reason is `document_blocks` being a per-revision snapshot:
  committing a revision writes a new row for **every** block, not only the
  edited one. A column there would be null on all twenty rows of a twenty-block
  document whenever one of them changed, and nineteen blocks would be
  re-embedded for nothing.

  No smarter write path fixes that -- to the database those nineteen rows
  really are new. Keeping a vector across a revision means keying it by the one
  thing a revision does not change, which is `block_id`.

  ## Why blocks are findable at all, rather than documents

  A block is independently addressable -- `rinto://block/{id}` -- so it is
  independently findable, and a hit lands on the section that says the thing
  rather than on a document that mentions it somewhere. `document_id` is how
  that hit ascends without a second call, the same second level the reference
  resolver and backlinks already hand back.

  Documents have no embedding of their own. Their findable content is their
  blocks, and every block hit already carries the way back up.

  ## `title` and `body` are stored, not just read

  They are what was embedded. Keeping them is what makes "has this changed
  since it was embedded" a comparison rather than a guess, which is what lets a
  rewrite keep a still-valid vector instead of clearing it on principle. See
  `RintoPMO.Embeddings` for the rule and what it is protecting against.

  ## Still an index, not a truth

  Every row is derived from a block, and `mix rinto.index.rebuild` puts them
  back. Same standing as `RintoPMO.Links.Link`.
  """

  use RintoPMO, :schema

  @type t :: %__MODULE__{}

  schema "block_embeddings" do
    field :block_id, UUIDv7

    field :title, :string
    field :body, :string

    field :project_id, UUIDv7
    field :document_id, UUIDv7
    field :archived, :boolean, default: false

    # Null means "needs embedding", and that is the whole of the state.
    field :embedding, Pgvector.Ecto.Vector

    timestamps()
  end

  @fields [:block_id, :title, :body, :project_id, :document_id, :archived]

  @doc false
  def changeset(%__MODULE__{} = block_embedding \\ %__MODULE__{}, attrs) do
    block_embedding
    |> cast(attrs, @fields)
    |> validate_required([:block_id, :document_id])
    |> unique_constraint(:block_id)
  end
end
