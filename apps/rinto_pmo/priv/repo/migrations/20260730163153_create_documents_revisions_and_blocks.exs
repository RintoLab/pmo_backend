defmodule RintoPMO.Repo.Migrations.CreateDocumentsRevisionsAndBlocks do
  use Ecto.Migration

  def change do
    create table(:documents, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :project_id,
          references(:projects, type: :binary_id, on_delete: :delete_all),
          null: true

      add :archived_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create index(:documents, [:project_id])

    create table(:document_revisions, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :document_id,
          references(:documents, type: :binary_id, on_delete: :delete_all),
          null: false

      add :parent_id, references(:document_revisions, type: :binary_id)
      add :title, :text, null: false
      add :change_summary, :text

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:document_revisions, [:document_id])
    create unique_index(:document_revisions, [:parent_id], where: "parent_id IS NOT NULL")

    create constraint(:document_revisions, :document_revisions_parent_differs_from_id,
             check: "parent_id IS NULL OR parent_id <> id"
           )

    create table(:document_blocks, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :block_id, :binary_id, null: false

      add :revision_id,
          references(:document_revisions, type: :binary_id, on_delete: :delete_all),
          null: false

      add :actor_id, references(:actors, type: :binary_id), null: false
      add :content, :text, null: false
      add :position, :integer, null: false
    end

    create unique_index(:document_blocks, [:revision_id, :block_id])
    create unique_index(:document_blocks, [:revision_id, :position])

    create constraint(:document_blocks, :document_blocks_position_non_negative,
             check: "position >= 0"
           )
  end
end
