defmodule RintoPMO.Repo.Migrations.AProposalIsOneLocalOperation do
  use Ecto.Migration

  # A proposal stops being able to be a whole document.
  #
  # The `:document` scope held a rewrite's structural operations in one row, so
  # inserting a section and deleting a paragraph were one thing to accept or
  # refuse. They are two edits, and a person reviewing them wants to take one
  # and leave the other. So the row becomes what it was already almost being:
  # **one local operation**, named by `operation`, with the scopes reduced to
  # the two that address something -- a block, or the title.
  #
  # An `insert` names the block it is going to create, allocated at propose time
  # rather than at commit, so the paragraph a person reviewed and the paragraph
  # that lands are the same one and can be argued about by id before it exists.
  #
  # Three columns are new state rather than payload:
  #
  #   * `staged` is the checkbox, and nothing else. It does not resolve a
  #     conflict and it does not decide what a publish contains.
  #   * `adopted_revision_id` is the revision that was on screen when somebody
  #     chose this candidate over the ones it competes with. It says both *that*
  #     it was adopted and *what was being looked at*, which is what lets a later
  #     read work out whether the choice still means anything.
  #   * `accepted_revision_id` is the revision that actually applied it.
  def up do
    alter table(:block_proposals) do
      add :operation, :string, null: false, default: "update"
      add :staged, :boolean, null: false, default: false
      add :after_block_id, :binary_id, null: true

      # Consecutive insertions from one propose call, so a reviewer taking the
      # first and the third gets them in the order they were written rather than
      # in whatever order the anchors happen to resolve.
      add :run_id, :binary_id, null: true
      add :run_ordinal, :integer, null: true

      add :adopted_revision_id, references(:document_revisions, type: :binary_id), null: true
      add :accepted_revision_id, references(:document_revisions, type: :binary_id), null: true

      # An explicit rewrite of one earlier intent by one later one. Not a
      # general graph: only the propose path writes it, and only where the new
      # row replaces exactly one old one.
      add :supersedes_id, references(:block_proposals, type: :binary_id), null: true

      add :decided_reason, :text, null: true
    end

    # `delete` and `move` carry no text, and the column has been mandatory since
    # the table only held replacements.
    execute "ALTER TABLE block_proposals ALTER COLUMN content DROP NOT NULL",
            "ALTER TABLE block_proposals ALTER COLUMN content SET NOT NULL"

    # The compiled operation list of a whole-document proposal. Nothing holds
    # one any more -- the operations *are* the rows -- and keeping the column
    # would leave two places a structural intent could be written.
    alter table(:block_proposals) do
      remove :block_ops, :jsonb, null: true
    end

    # The rows themselves went in the migration before this one. Repeated here
    # because a `:document` row written between the two -- a development
    # database, a topic still running the old client -- would otherwise stop the
    # constraint from installing, and the decision to drop them has already been
    # taken.
    execute "DELETE FROM block_proposals WHERE scope = 'document'", ""

    drop constraint(:block_proposals, :block_proposals_scope_valid)

    create constraint(:block_proposals, :block_proposals_scope_valid,
             check: "scope IN ('block', 'title')"
           )

    create constraint(:block_proposals, :block_proposals_operation_valid,
             check: "operation IN ('update', 'insert', 'delete', 'move')"
           )

    # Text belongs to the operations that write text. A `delete` carrying a body
    # would be a second, unreviewed opinion about what the block says.
    create constraint(:block_proposals, :block_proposals_content_matches_operation,
             check: "(operation IN ('update', 'insert')) = (content IS NOT NULL)"
           )

    # Only the two operations that say *where* may name an anchor. `NULL` is
    # allowed for an insertion at the head of the document, which has nothing to
    # follow.
    create constraint(:block_proposals, :block_proposals_anchor_matches_operation,
             check: "after_block_id IS NULL OR operation IN ('insert', 'move')"
           )

    # A title is one thing with one shape of change. `insert`, `delete` and
    # `move` have no meaning against a field on the revision.
    create constraint(:block_proposals, :block_proposals_title_updates_only,
             check: "scope <> 'title' OR operation = 'update'"
           )

    create constraint(:block_proposals, :block_proposals_run_complete,
             check: "(run_id IS NULL) = (run_ordinal IS NULL)"
           )

    # The slot a topic holds is now (block, operation), not (block). Rewriting a
    # paragraph and moving it are two intents about the same block that compose,
    # so a topic may hold both; two rewrites of it are still one intent
    # iterating and still cannot stand at once.
    drop unique_index(:block_proposals, [:block_id, :conversation_id],
           name: :block_proposals_one_live_per_block_and_conversation
         )

    create unique_index(:block_proposals, [:block_id, :conversation_id, :operation],
             where: "status = 'live' AND scope = 'block'",
             name: :block_proposals_one_live_per_block_operation_and_conversation
           )

    create index(:block_proposals, [:document_id, :status, :scope])
  end

  def down do
    drop index(:block_proposals, [:document_id, :status, :scope])

    drop unique_index(:block_proposals, [:block_id, :conversation_id, :operation],
           name: :block_proposals_one_live_per_block_operation_and_conversation
         )

    create unique_index(:block_proposals, [:block_id, :conversation_id],
             where: "status = 'live' AND scope = 'block'",
             name: :block_proposals_one_live_per_block_and_conversation
           )

    drop constraint(:block_proposals, :block_proposals_run_complete)
    drop constraint(:block_proposals, :block_proposals_title_updates_only)
    drop constraint(:block_proposals, :block_proposals_anchor_matches_operation)
    drop constraint(:block_proposals, :block_proposals_content_matches_operation)
    drop constraint(:block_proposals, :block_proposals_operation_valid)
    drop constraint(:block_proposals, :block_proposals_scope_valid)

    create constraint(:block_proposals, :block_proposals_scope_valid,
             check: "scope IN ('block', 'document', 'title')"
           )

    alter table(:block_proposals) do
      add :block_ops, :jsonb, null: true
    end

    # The rows a `:document` scope held were deleted by the migration before
    # this one and are not coming back; this restores the shape, not the data.
    execute "UPDATE block_proposals SET content = '' WHERE content IS NULL", ""

    execute "ALTER TABLE block_proposals ALTER COLUMN content SET NOT NULL",
            "ALTER TABLE block_proposals ALTER COLUMN content DROP NOT NULL"

    alter table(:block_proposals) do
      remove :decided_reason
      remove :supersedes_id
      remove :accepted_revision_id
      remove :adopted_revision_id
      remove :run_ordinal
      remove :run_id
      remove :after_block_id
      remove :staged
      remove :operation
    end
  end
end
