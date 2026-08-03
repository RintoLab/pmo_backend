defmodule RintoPMO.Repo.Migrations.CreateAttachments do
  use Ecto.Migration

  def change do
    create table(:attachments, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :actor_id, references(:actors, type: :binary_id), null: false
      add :filename, :string
      add :mime_type, :string, null: false
      add :byte_size, :bigint, null: false
      add :width, :integer, null: false
      add :height, :integer, null: false
      add :checksum, :string, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create index(:attachments, [:actor_id])
    create index(:attachments, [:checksum])

    create constraint(:attachments, :attachments_byte_size_positive, check: "byte_size > 0")
    create constraint(:attachments, :attachments_width_positive, check: "width > 0")
    create constraint(:attachments, :attachments_height_positive, check: "height > 0")
  end
end
