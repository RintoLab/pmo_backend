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

  ## It is a column, not a sort

  This used to be `DISTINCT ON (document_id) ... ORDER BY document_id, id DESC`
  over the whole of `document_revisions`, with nothing narrowing it. Every
  search, every backlink, every reference resolved and every embedding pass
  paid for a sort of every revision of every document that has ever existed --
  including the ones asking about a single block.

  `document_revisions.is_latest` and its partial unique index turn that into an
  index lookup whose cost tracks the number of documents rather than the number
  of edits ever made. It also makes "exactly one current revision per document"
  something the database enforces rather than something these queries assumed.

  The flag is maintained by `RintoPMO.Documents.insert_revision/4`, which
  demotes the parent before inserting its successor.
  """

  import Ecto.Query

  alias RintoPMO.Documents.DocumentRevision

  @doc """
  The current revision of every document.

  Unprojected on purpose: callers join this as a subquery for a title or an id,
  and one of them wants the row itself. A narrower select would be a second
  spelling of the same idea, which is what this module exists to prevent.
  """
  @spec latest() :: Ecto.Query.t()
  def latest do
    where(DocumentRevision, [revision], revision.is_latest)
  end
end
