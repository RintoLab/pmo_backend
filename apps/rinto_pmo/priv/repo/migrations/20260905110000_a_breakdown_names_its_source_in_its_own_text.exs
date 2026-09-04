defmodule RintoPMO.Repo.Migrations.ABreakdownNamesItsSourceInItsOwnText do
  @moduledoc """
  `document_decompositions` goes, along with the background job it recorded.

  The table was two things at once, and only one of them is being replaced.

  ## What it was as a job record

  `status`, `error`, and a partial unique index that stopped a second click
  starting a second model call. All of it existed because breaking a document
  down happened somewhere nobody could see: a person pressed a button, waited,
  and the row was the only thing that could say what was going on.

  Breaking a document down is now something a topic does -- a prompt shortcut,
  a model that writes the result with `rinto-pmo doc create`, and a
  conversation the person is watching the whole time. A conversation is a
  better progress display than any of those columns: it can be interrupted, and
  it can be argued with halfway through. So there is nothing left to record.

  ## What it was as an edge, and what replaces it

  `source_document_id` and `result_document_id` said which document a breakdown
  came out of. That mattered, and still does: `RintoPMO.Tasks.file_breakdown/1`
  points every filed task at the **source** as its spec.

  The breakdown now says so in its own first line, which the shortcut's prompt
  writes as `从 [标题](rinto://document/<id>) 拆出。` -- above the first heading,
  so `RintoPMO.Tasks.Breakdown` reads it as preamble and files nothing from it.
  `RintoPMO.Links` indexes it like any other reference, so the source is
  reachable from the breakdown and the breakdown from the source.

  That is a better place for it than a row: provenance written in the document
  survives being copied, exported and read by a person, and a document written
  by hand can carry it just by saying so.

  ## Rows are not migrated into anything

  There is nowhere to put them. A finished attempt's `result_document_id`
  points at a breakdown whose text was written before the preamble convention
  existed, and back-filling that line would mean editing documents -- creating
  a revision on each, signed by nobody, changing text somebody wrote.

  So existing breakdowns keep whatever their text already says, which for most
  of them is nothing, and file with no spec. That is an allowed outcome of
  `file_breakdown/1` and always has been: a breakdown written by hand has no
  source either.
  """

  use Ecto.Migration

  def up do
    drop table(:document_decompositions)
  end

  def down do
    create table(:document_decompositions, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :source_document_id,
          references(:documents, type: :binary_id, on_delete: :delete_all),
          null: false

      add :result_document_id,
          references(:documents, type: :binary_id, on_delete: :nilify_all),
          null: true

      add :status, :string, null: false, default: "pending"
      add :error, :text, null: true

      timestamps(type: :utc_datetime_usec)
    end

    create constraint(:document_decompositions, :document_decompositions_status_check,
             check: "status IN ('pending', 'running', 'succeeded', 'failed')"
           )

    create index(:document_decompositions, [:source_document_id])

    create unique_index(:document_decompositions, [:source_document_id],
             where: "status IN ('pending', 'running')",
             name: :document_decompositions_one_in_flight_per_source
           )
  end
end
