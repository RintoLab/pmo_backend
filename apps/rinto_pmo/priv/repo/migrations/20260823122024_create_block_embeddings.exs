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
  # ## What it holds
  #
  # The text as embedded, so that "has this changed since it was embedded" is a
  # comparison rather than a guess, plus the scope a query filters on and the
  # document a hit ascends to.
  def change do
    execute "CREATE EXTENSION IF NOT EXISTS vector", "DROP EXTENSION IF EXISTS vector"

    create table(:block_embeddings, primary_key: false) do
      add :id, :binary_id, primary_key: true

      # The block's stable identity, the one thing a revision does not change.
      add :block_id, :binary_id, null: false

      # A block has no title of its own; its first heading stands in for one.
      add :title, :text
      add :body, :text

      # Scope, which is the filter that matters first: finding the right thing
      # is usually a matter of looking in the right place.
      add :project_id, :binary_id, null: true

      # How a hit ascends. A block reference is followed by opening its document
      # at that block, and this is what saves the client a second lookup -- the
      # same second level `links` and the reference resolver already hand back.
      add :document_id, :binary_id, null: false

      # Carried rather than filtered out, so a caller decides whether archived
      # things belong in its list. Archiving is not deleting.
      add :archived, :boolean, null: false, default: false

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
    create index(:block_embeddings, [:project_id])

    # No index on `embedding`, deliberately. pgvector's own guidance is to add
    # one when scans get slow, because HNSW and IVFFlat are approximate: they
    # trade recall for speed, and recall is what this exists to provide. A few
    # thousand rows at 1024 dimensions is a scan of a few megabytes, which is
    # both faster and exact. One statement adds an index when something measures
    # a need for it.
  end
end
