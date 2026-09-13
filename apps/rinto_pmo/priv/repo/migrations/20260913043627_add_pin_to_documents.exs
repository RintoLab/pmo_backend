defmodule RintoPMO.Repo.Migrations.AddPinToDocuments do
  use Ecto.Migration

  # A person's bookmark, not a status. Existing rows stay unpinned: pinning is
  # a choice somebody makes, and claiming it for documents nobody has chosen
  # would put the whole corpus at the front, which is the same as putting none
  # of it there.
  def change do
    alter table(:documents) do
      add :pin, :boolean, null: false, default: false
    end
  end
end
