defmodule RintoPMO.Repo.Migrations.CreateAnnotationsAndReplies do
  use Ecto.Migration

  def change do
    create table(:annotations, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :document_id,
          references(:documents, type: :binary_id, on_delete: :delete_all),
          null: false

      add :actor_id, references(:actors, type: :binary_id), null: false
      add :block_id, :binary_id
      add :block_text, :text
      add :selected_text, :text
      add :content, :text, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create index(:annotations, [:document_id])

    create table(:annotation_replies, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :annotation_id,
          references(:annotations, type: :binary_id, on_delete: :delete_all),
          null: false

      add :actor_id, references(:actors, type: :binary_id), null: false
      add :content, :text, null: false
      add :position, :integer, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:annotation_replies, [:annotation_id, :position])

    create constraint(:annotation_replies, :annotation_replies_position_non_negative,
             check: "position >= 0"
           )
  end
end
