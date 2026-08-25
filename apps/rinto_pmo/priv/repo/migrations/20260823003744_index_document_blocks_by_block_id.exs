defmodule RintoPMO.Repo.Migrations.IndexDocumentBlocksByBlockId do
  use Ecto.Migration

  # `rinto://block/{id}` addresses a block on its own, so a block is now looked
  # up without knowing its document. The existing unique index leads with
  # `revision_id`, which a lookup by `block_id` alone cannot use.
  #
  # Not unique: a block_id repeats once per revision that carries the block --
  # that repetition is the version history, not a duplicate.
  def change do
    create index(:document_blocks, [:block_id])
  end
end
