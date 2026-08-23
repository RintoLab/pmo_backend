defmodule RintoPMO.Repo.Migrations.CreateLinks do
  use Ecto.Migration

  # Where the `rinto://` references written into bodies are indexed, so that
  # "what points at this?" is a query rather than a scan of every body in the
  # system.
  #
  # This table is an index, not a truth. Every row is derivable from the text
  # it was read out of, and `mix rinto.index.rebuild` is what makes that claim
  # something you can check rather than something the design merely asserts.
  def change do
    create table(:links, primary_key: false) do
      add :id, :binary_id, primary_key: true

      # document_block | annotation | annotation_reply | task | message
      #
      # Free-form rather than an enum, for the same reason `message_refs.ref_type`
      # is: the set grows with the system, and a body written today must not stop
      # loading because a later build added a kind of source.
      add :source_type, :string, null: false
      add :source_id, :binary_id, null: false

      # Which document the text lives in, where it lives in one. This is what
      # scopes the delete-and-reinsert when a document gains a revision.
      add :source_document_id, :binary_id, null: true

      add :target_type, :string, null: false
      add :target_id, :binary_id, null: true
      add :target_slug, :string, null: true

      # The link text as written. What a reader is shown when the target is
      # gone -- the same way an annotation degrades to its `block_text`.
      add :label, :text, null: false

      # Order of appearance within the source's own text.
      add :position, :integer, null: false

      # No `updated_at`: a row is never edited. A body that changes has its
      # rows deleted and rewritten, because the text is the truth and this only
      # follows it.
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    # No foreign keys, deliberately. Targets are polymorphic, and more to the
    # point a reference has to survive its target being deleted -- a dangling
    # link that can be reported as broken is the feature, not a defect to
    # cascade away. Source rows are cleaned up explicitly by `RintoPMO.Links`.

    create index(:links, [:target_type, :target_id])
    create index(:links, [:target_type, :target_slug])
    create index(:links, [:source_type, :source_id])
    create index(:links, [:source_document_id])
  end
end
