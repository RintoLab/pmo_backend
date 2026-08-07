defmodule RintoPMO.Repo.Migrations.CreateConversations do
  use Ecto.Migration

  def change do
    # No document_id and no annotation_id: "compare 《A》 and 《B》" is a single
    # topic spanning two documents, so a conversation belongs to none of them.
    # The conversation-to-annotation relation is many-to-many and is derived
    # from message_refs rather than materialised into a join table -- a join
    # table would be a lossy subset of message_refs, dropping *when* something
    # was pulled into context, which rebuilding a prompt needs.
    create table(:conversations, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :title, :string
      add :actor_id, references(:actors, type: :binary_id), null: true
      # Non-null means "hot": a pi process is, or was, carrying this topic.
      add :pi_session_id, :string, null: true

      timestamps(type: :utc_datetime_usec)
    end

    create index(:conversations, [:actor_id])
    create unique_index(:conversations, [:pi_session_id])

    create table(:messages, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :conversation_id,
          references(:conversations, type: :binary_id, on_delete: :delete_all),
          null: false

      add :actor_id, references(:actors, type: :binary_id), null: false
      add :role, :string, null: false
      # Raw text as typed or as produced -- never the expanded prelude. Replay
      # re-expands the refs against the documents as they are *then*, so that a
      # three-week-old snapshot is not fed back to the model.
      add :content, :text, null: false
      add :position, :integer, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:messages, [:conversation_id, :position])

    create constraint(:messages, :messages_position_non_negative, check: "position >= 0")

    create constraint(:messages, :messages_role_valid, check: "role IN ('user', 'assistant')")

    create table(:message_refs, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :message_id,
          references(:messages, type: :binary_id, on_delete: :delete_all),
          null: false

      add :ref_type, :string, null: false
      # Refs are expanded into the prelude in the order they were given, so
      # that order is part of what replay has to reproduce. It cannot be
      # recovered from the ids: UUIDv7 only orders by the millisecond, and a
      # message's refs are all written inside one.
      add :position, :integer, null: false
      add :ref_id, :binary_id, null: true
      # Annotations only: an annotation is reachable solely through its
      # document, the same rule PromptBuilder.resolve/1 enforces.
      add :ref_document_id, :binary_id, null: true
      # The ref map exactly as the client sent it. Kept alongside the
      # normalised columns because the two serve different jobs: payload is
      # what replay re-expands, ref_type/ref_id are what the reverse lookup
      # indexes. A project ref carries "slug" rather than "id", so neither can
      # be reconstructed from the other.
      add :payload, :map, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create index(:message_refs, [:message_id])

    # "Which topics discussed this annotation?" -- the reverse lookup the UI's
    # anchor badge is built on.
    create index(:message_refs, [:ref_type, :ref_id])

    # Deferred from the annotation-status migration: it references messages,
    # which did not exist yet. A reply carrying one is a conclusion drawn from
    # a conversation, and links back to the exact point it came from.
    alter table(:annotation_replies) do
      add :source_message_id,
          references(:messages, type: :binary_id, on_delete: :nilify_all),
          null: true
    end

    create index(:annotation_replies, [:source_message_id])
  end
end
