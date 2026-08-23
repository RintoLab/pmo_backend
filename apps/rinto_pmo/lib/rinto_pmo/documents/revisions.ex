defmodule RintoPMO.Documents.Revisions do
  @moduledoc """
  The one place that says which revision of a document counts.

  Almost everything that reads a document reads its newest revision, and
  everything that reads a **block** has to say so explicitly: block rows are
  per-revision snapshots that are never deleted, so a query that matches any
  revision will happily return a block that was removed three revisions ago.

  That was written out by hand in four places before this existed, and got
  wrong in one of them. It is the single most error-prone thing about this
  schema, which is reason enough for it to have one spelling.
  """

  import Ecto.Query

  alias RintoPMO.Documents.DocumentRevision

  @doc """
  The newest revision of every document, as a subquery to join against.

  `DISTINCT ON` rather than a correlated subquery per row: revisions are
  ordered by id, so the newest of each document is the first row of its group.
  """
  @spec latest() :: Ecto.Query.t()
  def latest do
    DocumentRevision
    |> distinct([revision], revision.document_id)
    |> order_by([revision], asc: revision.document_id, desc: revision.id)
    |> select([revision], %{
      id: revision.id,
      document_id: revision.document_id,
      title: revision.title
    })
  end
end
