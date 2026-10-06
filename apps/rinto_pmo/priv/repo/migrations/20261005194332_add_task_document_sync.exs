defmodule RintoPMO.Repo.Migrations.AddTaskDocumentSync do
  use Ecto.Migration

  def change do
    create table(:task_document_entries, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :document_id, references(:documents, type: :binary_id, on_delete: :restrict),
        null: false

      add :key, :string, null: false
      add :task_id, references(:tasks, type: :binary_id, on_delete: :nilify_all)

      add :revision_id, references(:document_revisions, type: :binary_id, on_delete: :restrict),
        null: false

      add :baseline, :map, null: false
      timestamps(type: :utc_datetime_usec)
    end

    # A document item identifies one task across retries and later revisions.
    # Keep the entry if its task is deleted, so a retry cannot resurrect it.
    create unique_index(:task_document_entries, [:document_id, :key])
    create index(:task_document_entries, [:task_id])
  end
end
