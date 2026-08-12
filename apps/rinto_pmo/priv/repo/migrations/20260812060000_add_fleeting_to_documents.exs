defmodule RintoPMO.Repo.Migrations.AddFleetingToDocuments do
  use Ecto.Migration

  def change do
    alter table(:documents) do
      add :fleeting, :boolean, null: false, default: false
    end
  end
end
