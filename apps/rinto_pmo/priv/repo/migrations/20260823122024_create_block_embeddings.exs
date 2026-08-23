defmodule RintoPMO.Repo.Migrations.CreateBlockEmbeddings do
  use Ecto.Migration

  # The one resource whose embedding cannot live on its own table.
  #
  # Every other findable thing keeps its vector as a column -- `tasks.embedding`,
  # `annotations.embedding`, and so on -- because the text it stands for is a
  # column on the same row, so a changeset can void the vector at the moment it
  # rewrites the text. Nothing is copied and nothing has to be kept in step.
  #
  # ## Why blocks are the exception
  #
  # `document_blocks` rows are per-revision snapshots, and committing a revision
  # writes a **new row for every block**, not only the changed ones (see
  # `RintoPMO.Documents.put_block_snapshots/2`). An embedding column there would
  # therefore be null on all twenty rows of a twenty-block document every time
  # somebody edited one of them, and the other nineteen would be re-embedded for
  # nothing.
  #
  # That is not something a smarter write path fixes: to the database those
  # nineteen rows genuinely are new. The only way to keep a vector across a
  # revision is to key it by something that survives one, which is `block_id`.
  #
  # ## What it holds, and what it deliberately does not
  #
  # The text as embedded -- so that "has this changed since it was embedded" is
  # a comparison rather than a guess -- the vector, and the document the block
  # belongs to.
  #
  # **Nothing that can be read from the document instead.** A block's project
  # and whether it is archived are properties of its document, and copying them
  # here would make this a second place they are recorded: one that has to be
  # rewritten every time the document is archived, or moved to another project,
  # by someone who remembered to. A search joins to `documents` for both, which
  # cannot go stale because there is nothing to keep in step.
  #
  # `document_id` stays because it is not a copy of anything mutable -- a block
  # belongs to one document for its whole life, and reconstructing that from
  # `document_blocks` would mean picking a revision first.
  def change do
    execute "CREATE EXTENSION IF NOT EXISTS vector", "DROP EXTENSION IF EXISTS vector"

    create table(:block_embeddings, primary_key: false) do
      add :id, :binary_id, primary_key: true

      # The block's stable identity, the one thing a revision does not change.
      add :block_id, :binary_id, null: false

      # What the vector was made from, which is what makes "has this changed
      # since it was embedded" a comparison rather than a guess. Also what the
      # reranker scores and what an excerpt is cut from.
      #
      # A heading is not stored beside it: that is the first line of this, and a
      # copy of a copy is one more thing to keep in step for nothing.
      add :body, :text

      # How a hit ascends. A block reference is followed by opening its document
      # at that block, and this is what saves the client a second lookup -- the
      # same second level `links` and the reference resolver already hand back.
      add :document_id, :binary_id, null: false

      # 1024 because that is what Qwen3-Embedding-0.6B produces. A literal
      # because it has to be: changing it rewrites the column, so it is a
      # decision made once rather than a setting left open.
      #
      # Null means "needs embedding", and that is the whole of the state. A
      # separate `embedded_at` would answer a question nobody asks -- when a row
      # last changed is already `updated_at`, and all a worker needs to know is
      # whether there is a vector.
      add :embedding, :vector, size: 1024

      timestamps(type: :utc_datetime_usec)
    end

    # One row per block: re-projecting replaces rather than accumulates.
    create unique_index(:block_embeddings, [:block_id])
    create index(:block_embeddings, [:document_id])

    # No index on `embedding`, deliberately. pgvector's own guidance is to add
    # one when scans get slow, because HNSW and IVFFlat are approximate: they
    # trade recall for speed, and recall is what this exists to provide. A few
    # thousand rows at 1024 dimensions is a scan of a few megabytes, which is
    # both faster and exact. One statement adds an index when something measures
    # a need for it.
  end
end
