defmodule RintoPMO.Repo.Migrations.AddLastUsedAtToAttachments do
  use Ecto.Migration

  def change do
    # NULL means "uploaded but never sent to an agent" -- the state an abandoned
    # upload stays in, and the one a future sweep can act on most safely. It is
    # deliberately distinct from "used long ago", so the two cannot be confused
    # by a policy that has not been decided yet.
    alter table(:attachments) do
      add :last_used_at, :utc_datetime_usec
    end

    # Supports the query a retention sweep will want: oldest-unused first.
    create index(:attachments, [:last_used_at])
  end
end
