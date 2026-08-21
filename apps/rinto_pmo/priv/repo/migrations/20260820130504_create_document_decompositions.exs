defmodule RintoPMO.Repo.Migrations.CreateDocumentDecompositions do
  use Ecto.Migration

  @moduledoc """
  One row per attempt to break a document down.

  The product of a decomposition is a document, not a row here. This records
  the *attempt*, and it earns a table by answering three questions that nothing
  else can:

    * a second click, while the first is still running, has to be refused --
      and the standing-breakdown check cannot see a run that has not produced
      anything yet
    * somebody is watching a spinner, so there has to be something to look at
      between the click and the document
    * a failure has to be reportable. Naming can fail quietly because it has a
      fallback; this cannot, and a reason that only reaches the log reaches
      nobody

  `result_document_id` is `nilify_all`: throwing away a bad breakdown must not
  erase the record of having made it. `source_document_id` is `delete_all`,
  because an attempt to break down a document that no longer exists is not a
  record of anything.

  The partial unique index is the guarantee rather than an optimisation. Two
  clicks landing together both pass a `SELECT` and the database refuses the
  second, which is the only place that can be decided.
  """

  def change do
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
