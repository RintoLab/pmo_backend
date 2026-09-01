defmodule RintoPMO.Repo.Migrations.OneActorStandsInForTheUnnamedAI do
  use Ecto.Migration

  def change do
    alter table(:actors) do
      add :default, :boolean, null: false, default: false
    end

    # At most one. Partial, so the flag costs nothing on every other row.
    create unique_index(:actors, [:default],
             where: "\"default\"",
             name: :actors_one_default
           )

    # What being the default *means*, as a fact rather than a convention: it is
    # an AI, and it carries no model configuration. A plain chat's model is the
    # one the person picked on the conversation, so a model recorded here would
    # be a second answer to a question this row does not answer.
    create constraint(:actors, :actors_default_has_no_model,
             check: """
             NOT "default"
             OR (kind = 'ai' AND provider IS NULL AND model IS NULL AND thinking_level IS NULL)
             """
           )
  end
end
