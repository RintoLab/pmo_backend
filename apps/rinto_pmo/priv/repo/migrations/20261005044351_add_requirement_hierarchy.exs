defmodule RintoPMO.Repo.Migrations.AddRequirementHierarchy do
  use Ecto.Migration

  def change do
    alter table(:requirements) do
      add :parent_id, references(:requirements, type: :binary_id, on_delete: :restrict)
    end

    create index(:requirements, [:project_id, :parent_id])

    create constraint(:requirements, :requirements_parent_not_self,
             check: "parent_id IS NULL OR parent_id <> id"
           )
  end
end
