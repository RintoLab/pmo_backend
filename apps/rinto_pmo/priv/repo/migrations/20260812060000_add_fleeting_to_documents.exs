defmodule RintoPMO.Repo.Migrations.AddFleetingToDocuments do
  use Ecto.Migration

  # Defaults to true because every document starts out as one nobody has
  # vouched for. Existing rows become fleeting for the same reason: the concept
  # is new, so none of them carries a record of having been adopted, and
  # claiming adoption the data cannot support is the worse of the two errors.
  def change do
    alter table(:documents) do
      add :fleeting, :boolean, null: false, default: true
    end
  end
end
