defmodule RintoPMO.Documents.Behaviour do
  @moduledoc false

  alias RintoPMO.Documents.Document
  alias RintoPMO.Documents.DocumentRevision

  @type filter :: :all | :unassigned | {:project, UUIDv7.t()}

  @callback list_documents(filter()) :: [Document.t()]
  @callback get_document!(UUIDv7.t()) :: Document.t()
  @callback create_document(map()) ::
              {:ok, Document.t()} | {:error, Ecto.Changeset.t()}
  @callback archive_document(Document.t()) ::
              {:ok, Document.t()} | {:error, Ecto.Changeset.t()}

  @callback list_revisions(Document.t()) :: [DocumentRevision.t()]
  @callback get_revision!(Document.t(), UUIDv7.t()) :: DocumentRevision.t()
  @callback create_revision(Document.t(), map()) ::
              {:ok, DocumentRevision.t()}
              | {:error, Ecto.Changeset.t()}
              | {:error, atom(), map()}
end
