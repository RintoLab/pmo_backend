defmodule RintoPMO.Tasks.SyncInput do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset
  alias RintoPMO.Tasks.SyncItem

  @primary_key false
  embedded_schema do
    field :base_revision_id, Ecto.UUID
    embeds_many :tasks, SyncItem
  end

  def parse(attrs) do
    %__MODULE__{}
    |> cast(attrs, [:base_revision_id])
    |> validate_required([:base_revision_id])
    |> cast_embed(:tasks, required: true)
    |> validate_length(:tasks, min: 1, max: 200)
    |> SyncItem.reject_unknown(attrs, ~w(base_revision_id tasks))
    |> unique_keys()
    |> apply_action(:insert)
  end

  defp unique_keys(changeset) do
    keys = Enum.map(get_field(changeset, :tasks, []), & &1.key)

    if length(keys) == length(Enum.uniq(keys)),
      do: changeset,
      else: add_error(changeset, :tasks, "keys must be unique within the document")
  end
end
