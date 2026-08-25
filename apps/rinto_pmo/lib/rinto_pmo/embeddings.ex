defmodule RintoPMO.Embeddings do
  @moduledoc """
  The one rule every embedding in this system obeys.

  A vector stands for a particular piece of text. The moment that text changes
  the vector is wrong, and `nil` is how a row says so -- there is no
  `embedded_at` beside it, because when a row last changed is already
  `updated_at` and the only question a worker asks is whether there is a vector.

  Which makes **what clears it** a decision about cost rather than correctness.
  Clearing on every write would send rows back through the embedding service
  for edits that changed nothing embeddable: a task's due date, a document
  being archived, a whole corpus being reindexed. So a vector is voided by the
  fields it was made from, and by nothing else.

  Every findable resource keeps its vector as a column on its own row, so this
  is a changeset concern -- local to the write, with no copy of the content and
  nothing to keep in step. Blocks are the one exception, for reasons
  `RintoPMO.Documents.BlockEmbedding` sets out.
  """

  import Ecto.Changeset

  @doc """
  Voids the embedding if any of `fields` is being changed.

  Call it after the fields have been cast, from the changeset that writes them.

      def changeset(task, attrs) do
        task
        |> cast(attrs, [:title, :description, :due_on])
        |> RintoPMO.Embeddings.invalidate([:title, :description])
      end

  A changeset that touches none of them leaves the vector alone, which is the
  whole point.
  """
  @spec invalidate(Ecto.Changeset.t(), [atom()]) :: Ecto.Changeset.t()
  def invalidate(%Ecto.Changeset{} = changeset, fields) when is_list(fields) do
    if Enum.any?(fields, &changed?(changeset, &1)) do
      force_change(changeset, :embedding, nil)
    else
      changeset
    end
  end
end
