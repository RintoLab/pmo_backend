defmodule RintoPMO.Repo.Migrations.AddDocumentClassification do
  use Ecto.Migration

  def change do
    alter table(:documents) do
      add :kind, :string, null: false, default: "general"

      add :requirement_id,
          references(:requirements, type: :binary_id, on_delete: :restrict)
    end

    create index(:documents, [:requirement_id, :kind])

    create constraint(:documents, :documents_requirement_project_check,
             check: "requirement_id IS NULL OR project_id IS NOT NULL"
           )

    create constraint(:documents, :documents_kind_check,
             check: "kind IN ('general', 'rfc', 'spec', 'plan', 'task')"
           )
  end
end
