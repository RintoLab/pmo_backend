defmodule RintoPMO.Repo.Migrations.CreatePromptShortcuts do
  use Ecto.Migration

  def change do
    # The quick prompts offered beside the composer, chosen by what the message
    # already references. Rows rather than code so that adding one is a request
    # instead of a deploy -- which is the whole point of the table.
    create table(:prompt_shortcuts, primary_key: false) do
      add :id, :binary_id, primary_key: true

      # Stable across deploys, which the id is not: the seeding task has to find
      # the row it wrote last time, and a fresh UUID every run would make its
      # upsert an insert. Random rather than a readable slug on purpose --
      # nothing should be branching on it, and `k7f3q2x9m4` invites that less
      # than `review-document` does.
      add :key, :string, null: false

      # One reference type, from `RintoPMO.References.types()`. Null means the
      # shortcut is offered when the composer references nothing at all.
      add :resource_type, :string, null: true

      add :label, :string, null: false
      add :icon, :string, null: true

      add :prompt, :text, null: false

      # What the seeding task last wrote, kept beside the live prompt so that
      # "has this been edited?" is one comparison and "put it back" is one
      # write. Null marks a row somebody created through the API: there is no
      # default to return it to.
      add :default_prompt, :text, null: true

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:prompt_shortcuts, [:key])

    # Every render of the composer filters by this, and the table is small
    # enough that the index is really about intent rather than speed.
    create index(:prompt_shortcuts, [:resource_type])
  end
end
