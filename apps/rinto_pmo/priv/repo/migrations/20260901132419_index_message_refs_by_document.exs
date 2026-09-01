defmodule RintoPMO.Repo.Migrations.IndexMessageRefsByDocument do
  use Ecto.Migration

  def change do
    # `GET /conversations?document_id=` asks which topics touched a document.
    # Half the answer comes from the existing (ref_type, ref_id) index -- the
    # direct `document` refs -- and the other half from here: the annotations,
    # proposals and other document-internal resources that name the document
    # they live in. Neither index covers the other's half, so both stay.
    create index(:message_refs, [:ref_document_id])
  end
end
