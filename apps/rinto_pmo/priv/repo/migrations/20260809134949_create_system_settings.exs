defmodule RintoPMO.Repo.Migrations.CreateSystemSettings do
  use Ecto.Migration

  def change do
    # Which actor plays a given system-wide role. One row per role, and every
    # row points at an actor -- this is deliberately not a key/value store: a
    # setting that is not an actor gets a column of its own rather than a blob
    # nobody can query.
    #
    # The roles themselves live in `RintoPMO.Settings`, not in a check
    # constraint, because adding one is a code change either way and a
    # constraint would make it a migration as well.
    create table(:system_settings, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :key, :string, null: false

      # Nullable, and nulled rather than deleted when the actor goes: a role
      # with nobody in it is a state the system handles (it falls back), while
      # a row pointing at an actor that no longer exists is not.
      add :actor_id, references(:actors, type: :binary_id, on_delete: :nilify_all), null: true

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:system_settings, [:key])
    create index(:system_settings, [:actor_id])
  end
end
