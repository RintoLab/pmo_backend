defmodule RintoPMO.Repo.Migrations.DropTokenFromActors do
  use Ecto.Migration

  @moduledoc """
  Takes the token back out of the database.

  It was never data about a person. The token is agreed in advance and written
  into the configuration of each thing that holds one -- the server, the CLI,
  the editor -- so the server's copy belongs with the rest of its configuration
  and not in a row it would then have to hand out. See `RintoPMO.Actors`.

  Identity survives it: the token says the caller is the person this
  installation belongs to, and that person is found by being the human actor.
  """

  def up do
    drop constraint(:actors, :actors_token_human_only)
    drop unique_index(:actors, [:token])

    alter table(:actors) do
      remove :token
    end
  end

  def down do
    alter table(:actors) do
      add :token, :string, null: true
    end

    create unique_index(:actors, [:token])

    create constraint(:actors, :actors_token_human_only, check: "token IS NULL OR kind = 'human'")
  end
end
