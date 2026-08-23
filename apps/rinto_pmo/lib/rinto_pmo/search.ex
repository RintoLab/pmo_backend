defmodule RintoPMO.Search do
  @moduledoc """
  Maintains the projection everything findable is projected into.

  Only the write side lives here for now. Retrieval will be semantic -- query
  embedding against row embedding -- and neither the embedding column nor the
  query path exists yet. The projection does, because "which text represents
  this resource" is the same question whichever way it is later matched, and it
  has to follow edits regardless.

  Every function takes a `repo` and runs inside the transaction that wrote the
  resource, for the same reason `RintoPMO.Links` does: a projection written in a
  second transaction has a window where the resource says one thing and
  discovery says another.

  ## Replacing, not accumulating

  A resource has exactly one row, upserted on `(resource_type, resource_id)`. A
  body that changed is re-projected over the top, so nothing has to diff and
  nothing can drift.
  """

  use RintoPMO, :context

  alias RintoPMO.Search.Searchable

  @doc """
  Writes or replaces one resource's projection.

  `fields` takes `:title`, `:body`, `:project_id`, `:document_id` and
  `:archived`, all optional. A resource with neither title nor body is removed
  instead of stored: an empty row can never be a hit, and keeping it would make
  every count wrong.

  ## The vector is kept unless the text it represents changed

  `title` and `body` are what gets embedded. Everything else on the row --
  scope, the archived flag -- can change without making an existing vector
  wrong, and clearing it there would send the row back through the embedding
  service for no reason.

  The case that matters is `RintoPMO.ContentIndex.rebuild/1`: it re-projects
  every resource in the system, and a blind clear would turn a repair into a
  full re-embedding of the entire corpus. Archiving a document, or moving a
  task, would each do a smaller version of the same thing.
  """
  @spec sync(Ecto.Repo.t(), String.t(), UUIDv7.t(), map()) :: :ok
  def sync(repo, resource_type, resource_id, fields) do
    if blank?(fields[:title]) and blank?(fields[:body]) do
      purge(repo, resource_type, resource_id)
    else
      attrs =
        fields
        |> Map.take([:title, :body, :project_id, :document_id, :archived])
        |> Map.merge(%{resource_type: resource_type, resource_id: resource_id})

      %Searchable{}
      |> Searchable.changeset(attrs)
      |> repo.insert!(
        on_conflict: replacements(),
        conflict_target: [:resource_type, :resource_id]
      )

      :ok
    end
  end

  # `:replace` cannot express "clear this column only when those two changed",
  # so the condition is written as the update itself: `embedding` is set to null
  # where the incoming text differs from the stored text, and to its own current
  # value where it does not.
  defp replacements do
    from searchable in Searchable,
      update: [
        set: [
          title: fragment("EXCLUDED.title"),
          body: fragment("EXCLUDED.body"),
          project_id: fragment("EXCLUDED.project_id"),
          document_id: fragment("EXCLUDED.document_id"),
          archived: fragment("EXCLUDED.archived"),
          updated_at: fragment("EXCLUDED.updated_at"),
          embedding:
            fragment(
              """
              CASE
                WHEN ? IS DISTINCT FROM EXCLUDED.title OR ? IS DISTINCT FROM EXCLUDED.body
                THEN NULL
                ELSE ?
              END
              """,
              searchable.title,
              searchable.body,
              searchable.embedding
            )
        ]
      ]
  end

  @doc """
  Removes one resource's projection.
  """
  @spec purge(Ecto.Repo.t(), String.t(), UUIDv7.t()) :: :ok
  def purge(repo, resource_type, resource_id) do
    Searchable
    |> where([searchable], searchable.resource_type == ^resource_type)
    |> where([searchable], searchable.resource_id == ^resource_id)
    |> repo.delete_all()

    :ok
  end

  @doc """
  Removes the projections of a document's blocks other than `keep`.

  Written this way round rather than "delete them all and re-insert", because
  deleting a projection throws away its embedding. A revision usually changes
  one block out of many, and rewriting the lot would send every untouched block
  back through the embedding service on every commit.

  What this is for is the block a revision *dropped*: it has no projection to
  rewrite, so it has to be named as absent instead.
  """
  @spec purge_blocks_except(Ecto.Repo.t(), UUIDv7.t(), [UUIDv7.t()]) :: :ok
  def purge_blocks_except(repo, document_id, keep) when is_list(keep) do
    Searchable
    |> where([searchable], searchable.resource_type == "block")
    |> where([searchable], searchable.document_id == ^document_id)
    |> where([searchable], searchable.resource_id not in ^keep)
    |> repo.delete_all()

    :ok
  end

  defp blank?(nil), do: true
  defp blank?(text) when is_binary(text), do: String.trim(text) == ""
  defp blank?(_other), do: false
end
