defmodule RintoPMO.Repo.Migrations.ReplaceDocumentFleetingWithStatus do
  use Ecto.Migration

  @moduledoc """
  Turns the fleeting flag into a three-valued status.

  A boolean can say whether anybody has vouched for a document. It cannot say
  whether the document has already been *used* -- and that is the question two
  things now ask before acting: decomposition asks it of a source document, and
  filing a task document as a work breakdown asks it of that document.

  So the axis is "can this still be consumed by something downstream":

    * `draft` -- nobody has vouched for it yet, so nothing may consume it
    * `formal` -- somebody has, so the things that consume documents may
    * `applied` -- already consumed once, and once is all there is

  `formal` is a finished state, not a waiting room. Most documents never go
  further, because most documents are not there to be turned into anything.

  `archived_at` stays where it is. Archiving is a different question that can
  be asked of a document in any of these states, and folding it in here would
  lose both the distinction and the time it happened.
  """

  def up do
    alter table(:documents) do
      add :status, :string, null: false, default: "draft"
    end

    # Adopted documents are the ones that carried information; everything else
    # was fleeting because that is what every document starts as.
    execute "UPDATE documents SET status = 'formal' WHERE fleeting = false"

    alter table(:documents) do
      remove :fleeting
    end

    create constraint(:documents, :documents_status_check,
             check: "status IN ('draft', 'formal', 'applied')"
           )

    create index(:documents, [:status])
  end

  def down do
    alter table(:documents) do
      add :fleeting, :boolean, null: false, default: true
    end

    # `applied` collapses into `formal` on the way back: the boolean has no way
    # to say a document was consumed, and reporting it as never adopted would
    # be the worse of the two lies.
    execute "UPDATE documents SET fleeting = false WHERE status IN ('formal', 'applied')"

    drop index(:documents, [:status])
    drop constraint(:documents, :documents_status_check)

    alter table(:documents) do
      remove :status
    end
  end
end
