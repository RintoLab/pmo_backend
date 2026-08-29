defmodule RintoPMO.Repo.Migrations.ReplaceAnnotationStatusWithConfirmation do
  @moduledoc """
  An annotation has no status. It has a mark somebody put on it, or it has not.

  `status` was three values -- `open`, `resolved`, `dismissed` -- and two of
  them were the same answer with a reason attached: the thread is over. Which
  reason it was is already recorded next to it, and better: `resolved` carried
  the revision that settled it, `dismissed` carried nothing because nothing
  changed. So the distinction lives in whether that pointer is there, and
  spending a state on it said the same thing twice.

  What replaces it is `confirmed_at`, on the model of `documents.archived_at`
  -- which that schema's own docs are careful to call "not a status". Null is
  unconfirmed. A timestamp also answers *when*, which an enum never could.

  `confirmed_by_revision_id` is the old `resolved_by_revision_id` renamed and
  otherwise unchanged: present when the confirmation came with a change to the
  document, absent when somebody looked and decided it needed none.

  ## `source_message_id` goes with it

  It was how "a conclusion came out of a topic" was recorded, and it was the
  judgement behind a marker that said "the AI has spoken, it is your turn".
  Both are gone: an AI reply is now something a person asks for one at a time,
  and conversations no longer write to annotations at all. A nullable column
  that nothing writes and nothing reads is worse than no column -- the next
  reader finds it and builds on a path that was never wired up.

  ## The backfill

  Rows that were `resolved` or `dismissed` take `updated_at` as the moment they
  were confirmed. That is an **upper bound and not the measurement**: an
  annotation edited after it was confirmed reports the edit. The real instant
  was never recorded, and the alternative -- leaving them null -- would hand
  back every settled thread as unsettled, which is a worse lie about more rows.
  """

  use Ecto.Migration

  def up do
    alter table(:annotations) do
      add :confirmed_at, :utc_datetime_usec

      add :confirmed_by_revision_id,
          references(:document_revisions, type: :binary_id, on_delete: :nilify_all)
    end

    flush()

    execute """
    UPDATE annotations
       SET confirmed_at = updated_at,
           confirmed_by_revision_id = resolved_by_revision_id
     WHERE status <> 'open'
    """

    drop constraint(:annotations, :annotations_status_valid)
    drop index(:annotations, [:document_id, :status])

    alter table(:annotations) do
      remove :status
      remove :resolved_by_revision_id
    end

    # The same question the old index served -- "what is still unconfirmed on
    # this document" -- against the column that now answers it.
    create index(:annotations, [:document_id, :confirmed_at])

    alter table(:annotation_replies) do
      remove :source_message_id
    end
  end

  def down do
    alter table(:annotation_replies) do
      add :source_message_id, references(:messages, type: :binary_id, on_delete: :nilify_all)
    end

    alter table(:annotations) do
      add :status, :string, null: false, default: "open"

      add :resolved_by_revision_id,
          references(:document_revisions, type: :binary_id, on_delete: :nilify_all)
    end

    flush()

    # Everything confirmed comes back as `resolved`, including what was
    # dismissed: which of the two it had been is not recoverable from a
    # timestamp, and `resolved` is the one that can carry the pointer.
    execute """
    UPDATE annotations
       SET status = 'resolved',
           resolved_by_revision_id = confirmed_by_revision_id
     WHERE confirmed_at IS NOT NULL
    """

    drop index(:annotations, [:document_id, :confirmed_at])

    alter table(:annotations) do
      remove :confirmed_at
      remove :confirmed_by_revision_id
    end

    create index(:annotations, [:document_id, :status])

    create constraint(:annotations, :annotations_status_valid,
             check: "status IN ('open', 'resolved', 'dismissed')"
           )
  end
end
