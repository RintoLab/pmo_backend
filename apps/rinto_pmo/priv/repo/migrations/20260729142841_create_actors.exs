defmodule RintoPMO.Repo.Migrations.CreateActors do
  use Ecto.Migration

  def change do
    create table(:actors, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :kind, :string, null: false
      add :name, :string, null: false
      add :description, :text
      add :enabled, :boolean, null: false, default: true
      add :provider, :string
      add :model, :string
      add :thinking_level, :string
      add :system_prompt, :text
      add :injection_profile, :map

      timestamps(type: :utc_datetime_usec)
    end
  end
end
