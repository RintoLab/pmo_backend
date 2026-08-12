defmodule RintoPMO.Repo.Migrations.AddTokenToActors do
  use Ecto.Migration

  def change do
    alter table(:actors) do
      # Nullable because only a human carries one: an AI actor is named by
      # whoever is already holding a token, and has no way to make a request
      # of its own.
      add :token, :string, null: true
    end

    # Unique so that a token identifies exactly one actor even after this
    # system stops assuming there is only one person in it.
    create unique_index(:actors, [:token])

    create constraint(:actors, :actors_token_human_only, check: "token IS NULL OR kind = 'human'")
  end
end
