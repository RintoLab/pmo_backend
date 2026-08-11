defmodule RintoPMO.Repo.Migrations.AddScopeToBlockProposals do
  use Ecto.Migration

  # A proposal stops being only about one block.
  #
  # `:block` is what the table has held until now -- new content for one block,
  # identified by (block, conversation). Two new scopes join it, both of which
  # are about the document rather than a block inside it, and therefore carry no
  # `block_id`:
  #
  #   * `:document` -- whole-document markdown, compiled into a block operation
  #     list at propose time. The only way to express a change that splits,
  #     merges, inserts or reorders blocks: a `:block` proposal can only ever
  #     become an `update` op, so structural edits had no vocabulary at all.
  #
  #   * `:title` -- a document's title, which lives on the revision and is
  #     never read out of the body (see `RintoPMO.Documents.Markdown`), so it
  #     cannot ride along inside a `:document` proposal's markdown.
  def change do
    alter table(:block_proposals) do
      add :scope, :string, null: false, default: "block"

      # The compiled block operations for a `:document` proposal, against
      # `base_revision_id`. Stored rather than recomputed at commit time
      # because it is what a human reviewed and approved; the staleness rule on
      # document-scope commits is what keeps it from being applied to a
      # document that has moved since.
      add :block_ops, :jsonb, null: true

      # What the proposer says it changed, carried into the revision on commit.
      # Optional: a one-block edit speaks for itself, a whole-document rewrite
      # is easier to review with a sentence in front of it.
      add :change_summary, :text, null: true
    end

    # Only a `:block` proposal names a block. The two document-level scopes
    # cannot, and a `:block` proposal without one has no identity at all.
    execute "ALTER TABLE block_proposals ALTER COLUMN block_id DROP NOT NULL",
            "ALTER TABLE block_proposals ALTER COLUMN block_id SET NOT NULL"

    create constraint(:block_proposals, :block_proposals_scope_valid,
             check: "scope IN ('block', 'document', 'title')"
           )

    create constraint(:block_proposals, :block_proposals_scope_consistent,
             check: "(scope = 'block') = (block_id IS NOT NULL)"
           )

    # The existing index already fails to reach the new scopes -- Postgres holds
    # NULLs distinct, so two rows with a null `block_id` never collide in it --
    # but saying `scope = 'block'` makes that a decision rather than an accident.
    drop unique_index(:block_proposals, [:block_id, :conversation_id],
           name: :block_proposals_one_live_per_block_and_conversation
         )

    create unique_index(:block_proposals, [:block_id, :conversation_id],
             where: "status = 'live' AND scope = 'block'",
             name: :block_proposals_one_live_per_block_and_conversation
           )

    # The same "one live slot per topic" rule the block scope has, for the
    # scopes that are keyed by document instead. `scope` is in the index so a
    # topic can hold a live title proposal and a live document proposal at once:
    # they change different things and neither is an alternative to the other.
    create unique_index(:block_proposals, [:document_id, :conversation_id, :scope],
             where: "status = 'live' AND scope <> 'block'",
             name: :block_proposals_one_live_document_scope_per_conversation
           )
  end
end
