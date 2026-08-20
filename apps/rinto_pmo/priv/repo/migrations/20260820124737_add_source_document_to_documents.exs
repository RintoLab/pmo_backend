defmodule RintoPMO.Repo.Migrations.AddSourceDocumentToDocuments do
  use Ecto.Migration

  @moduledoc """
  Records which document a document was derived from.

  Task decomposition reads a formal document and writes a new one. Two things
  need that edge afterwards and neither can reconstruct it: whether a source
  document has already been broken down (there may be only one live breakdown
  of it at a time), and what to show on the source document itself.

  Deliberately not the same edge as `tasks.document_id`. That one points at the
  spec somebody implements against, which is the *source* document -- so the
  breakdown would be unreachable from the tasks if this column did not exist.

  `nilify_all` rather than `delete_all`: a task document outlives the document
  it was derived from. Losing the source is losing provenance, not losing the
  breakdown -- the same trade `tasks.document_id` makes.
  """

  def change do
    alter table(:documents) do
      add :source_document_id,
          references(:documents, type: :binary_id, on_delete: :nilify_all),
          null: true
    end

    create index(:documents, [:source_document_id])
  end
end
