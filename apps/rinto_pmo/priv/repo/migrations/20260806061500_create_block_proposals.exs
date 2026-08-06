defmodule RintoPMO.Repo.Migrations.CreateBlockProposals do
  use Ecto.Migration

  def change do
    create table(:block_proposals, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :document_id,
          references(:documents, type: :binary_id, on_delete: :delete_all),
          null: false

      add :block_id, :binary_id, null: false

      # nilify_all rather than delete_all: a proposal's life does not follow the
      # topic that made it. The topic can go; the proposal, and the record of
      # what was decided about it, stays.
      add :conversation_id,
          references(:conversations, type: :binary_id, on_delete: :nilify_all),
          null: true

      # Who wrote the proposed text. The block snapshot a commit produces
      # requires an author, and it has to be the proposer -- attributing it to
      # whoever approved it would lose the fact that an AI wrote it.
      add :actor_id, references(:actors, type: :binary_id), null: false

      add :content, :text, null: false

      # The revision this was written against. Kept for the record, not as a
      # conflict test: a working copy is loaded per-document from the latest
      # revision, so every topic's base is equal by construction and could
      # never discriminate between them.
      add :base_revision_id,
          references(:document_revisions, type: :binary_id),
          null: false

      add :status, :string, null: false, default: "live"
      add :decided_by_actor_id, references(:actors, type: :binary_id), null: true
      add :decided_at, :utc_datetime_usec, null: true

      timestamps(type: :utc_datetime_usec)
    end

    create constraint(:block_proposals, :block_proposals_status_valid,
             check: "status IN ('live', 'accepted', 'rejected', 'superseded')"
           )

    # A decision names both who made it and when, or neither.
    create constraint(:block_proposals, :block_proposals_decision_complete,
             check: """
             (decided_by_actor_id IS NULL) = (decided_at IS NULL)
             """
           )

    # "One live proposal per block per topic" -- the whole concurrency model
    # rests on this. A topic revising the same block five times updates its one
    # proposal in place rather than stacking five, so the contention test can
    # stay as simple as counting live rows.
    create unique_index(:block_proposals, [:block_id, :conversation_id],
             where: "status = 'live'",
             name: :block_proposals_one_live_per_block_and_conversation
           )

    create index(:block_proposals, [:document_id, :status])

    alter table(:document_revisions) do
      # Which discussion produced this revision. The reverse -- "what did that
      # discussion change?" -- is then a query rather than a stored entity, the
      # same choice message_refs makes.
      add :source_conversation_id,
          references(:conversations, type: :binary_id, on_delete: :nilify_all),
          null: true
    end

    create index(:document_revisions, [:source_conversation_id])
  end
end
