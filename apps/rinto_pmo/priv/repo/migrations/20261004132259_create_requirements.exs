defmodule RintoPMO.Repo.Migrations.CreateRequirements do
  use Ecto.Migration

  def change do
    create table(:requirements, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :project_id, references(:projects, type: :binary_id, on_delete: :restrict), null: false
      add :title, :string, null: false
      add :description, :text, null: false, default: ""
      add :status, :string, null: false, default: "draft"
      add :archived_at, :utc_datetime_usec
      timestamps(type: :utc_datetime_usec)
    end

    create index(:requirements, [:project_id, :inserted_at])

    create constraint(:requirements, :requirements_status_check,
             check: "status IN ('draft', 'active', 'completed', 'cancelled')"
           )
  end
end
