defmodule RintoPMO.Repo.Migrations.AddEmbeddingsToDocumentBlocks do
  use Ecto.Migration

  # A block's vector, on the block.
  #
  # ## Why this looked impossible
  #
  # `document_blocks` rows are per-revision snapshots, and committing a revision
  # writes a new row for **every** block rather than only the edited one. A
  # column here would therefore be null on all twenty rows of a twenty-block
  # document whenever somebody changed one of them, and the other nineteen would
  # be re-embedded for nothing.
  #
  # ## Why it is not
  #
  # The write path already holds the previous revision's blocks -- it applies
  # the operations against them -- so at the moment the new rows are built, the
  # old content and the old vectors are in memory. A block whose content is
  # unchanged carries its vector forward; one that changed starts null. No extra
  # query, and no comparison at read time: **the invalidation is structural.**
  #
  # This replaces a separate `block_embeddings` table keyed by `block_id`, built
  # on the belief that a vector could not survive a revision. It could. That
  # table also had to carry a copy of the block's text to compare against, a
  # copy of the document id, and -- for a while -- copies of the document's
  # project and archived flag, each of which was somewhere for the truth to
  # drift away from.
  #
  # Superseded rows have their vectors cleared as the new revision lands, so
  # only the current snapshot of a block carries one. History is not searched,
  # and 4KB per row per revision is not worth keeping to answer nothing.
  def change do
    execute "CREATE EXTENSION IF NOT EXISTS vector", "DROP EXTENSION IF EXISTS vector"

    alter table(:document_blocks) do
      # 1024 because that is what Qwen3-Embedding-0.6B produces. A literal
      # because it has to be: changing it rewrites the column.
      #
      # Null means "needs embedding", and that is the whole of the state.
      add :embedding, :vector, size: 1024
    end
  end
end
