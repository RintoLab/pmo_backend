defmodule RintoPMO.Repo.Migrations.AConversationIsArchivedNotDeleted do
  use Ecto.Migration

  def change do
    alter table(:conversations) do
      # Presentation, not destruction. A topic is the only record of why a
      # passage reads the way it does, so the row stays; this is how it leaves
      # the list. Null means it is still in use.
      add :archived_at, :utc_datetime_usec
    end
  end
end
