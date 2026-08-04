defmodule RintoPMO.Repo.Migrations.AddStatusToAnnotations do
  use Ecto.Migration

  def change do
    alter table(:annotations) do
      add :status, :string, null: false, default: "open"

      add :resolved_by_revision_id,
          references(:document_revisions, type: :binary_id, on_delete: :nilify_all)
    end

    # The annotation list is always scoped to a document and, once status
    # exists, almost always to a status as well ("what is still open here").
    create index(:annotations, [:document_id, :status])

    create constraint(:annotations, :annotations_status_valid,
             check: "status IN ('open', 'resolved', 'dismissed')"
           )
  end
end
