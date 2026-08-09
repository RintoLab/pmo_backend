defmodule RintoPMO.Repo.Migrations.AddTitleSourceToConversations do
  use Ecto.Migration

  def up do
    alter table(:conversations) do
      add :title_source, :string
      add :title_generated_at, :utc_datetime_usec
    end

    # Every title that exists today was set by whoever created or renamed the
    # topic, so it is manual by definition. Leaving these null would offer them
    # to the auto-namer, which is allowed to overwrite nothing but its own work.
    execute("UPDATE conversations SET title_source = 'manual' WHERE title IS NOT NULL")
  end

  def down do
    alter table(:conversations) do
      remove :title_source
      remove :title_generated_at
    end
  end
end
