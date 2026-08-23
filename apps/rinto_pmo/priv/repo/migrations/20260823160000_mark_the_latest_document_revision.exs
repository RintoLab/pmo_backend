defmodule RintoPMO.Repo.Migrations.MarkTheLatestDocumentRevision do
  use Ecto.Migration

  # Which revision of a document counts, as a column instead of as a sort.
  #
  # Almost every read of a document -- and every read of a block, which is a
  # per-revision snapshot -- has to say "the newest revision of each document"
  # first. That was a `DISTINCT ON (document_id) ... ORDER BY document_id, id
  # DESC` over the whole of `document_revisions`, with no `WHERE` to narrow it,
  # sitting under search, backlinks, reference resolution and every embedding
  # pass.
  #
  # The cost of that sort grows with the number of edits this installation has
  # ever made. Not with the number of documents, not with how many rows the
  # query actually wants: resolving one block's references sorted every
  # revision of every document that has ever existed. Cheap today because the
  # table is small, and never getting cheaper.
  #
  # A partial unique index also makes "exactly one current revision per
  # document" something the database enforces, where before it was a property
  # the queries assumed and nothing checked.
  def change do
    alter table(:document_revisions) do
      add :is_latest, :boolean, null: false, default: true
    end

    flush()

    # The backfill is the definition it replaces, run once. Written against
    # `DISTINCT ON` rather than "has no child" so that a history with a broken
    # `parent_id` chain lands on exactly the revision the old queries would
    # have returned, rather than on a more defensible one nothing agreed with.
    execute(
      """
      UPDATE document_revisions AS revision
      SET is_latest = revision.id IN (
        SELECT DISTINCT ON (document_id) id
        FROM document_revisions
        ORDER BY document_id, id DESC
      )
      """,
      ""
    )

    # Partial, so superseded revisions are not in it at all: the index holds one
    # row per document rather than one per edit ever made.
    #
    # It cannot be deferred -- a partial unique index is not a constraint -- so
    # a document gaining a revision has to demote the old one before inserting
    # the new one, in that order. `RintoPMO.Documents.insert_revision/4` does.
    create unique_index(:document_revisions, [:document_id],
             where: "is_latest",
             name: :document_revisions_one_latest_per_document
           )
  end
end
