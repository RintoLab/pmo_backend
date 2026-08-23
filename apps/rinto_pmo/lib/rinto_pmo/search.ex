defmodule RintoPMO.Search do
  @moduledoc """
  Maintains the projection everything findable is projected into.

  Only the write side lives here for now. **How a query is answered is
  deliberately not settled yet** -- see `RintoPMO.ContentIndex` on why the
  projection is worth building before that is decided.

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
        on_conflict:
          {:replace, [:title, :body, :project_id, :document_id, :archived, :updated_at]},
        conflict_target: [:resource_type, :resource_id]
      )

      :ok
    end
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
  Removes every projection a document's blocks had.

  Used before re-projecting a revision, because a revision can drop a block and
  a per-block rewrite would leave the dropped one findable.
  """
  @spec purge_blocks(Ecto.Repo.t(), UUIDv7.t()) :: :ok
  def purge_blocks(repo, document_id) do
    Searchable
    |> where([searchable], searchable.resource_type == "block")
    |> where([searchable], searchable.document_id == ^document_id)
    |> repo.delete_all()

    :ok
  end

  defp blank?(nil), do: true
  defp blank?(text) when is_binary(text), do: String.trim(text) == ""
  defp blank?(_other), do: false
end
