defmodule RintoPMO.Tasks.SyncItem do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false
  embedded_schema do
    field :key, :string
    field :title, :string
    field :description, :string
    field :repo_id, Ecto.UUID
  end

  def changeset(item, attrs) do
    item
    |> cast(attrs, [:key, :title, :description, :repo_id])
    |> validate_required([:key, :title, :repo_id])
    |> validate_format(:key, ~r/\A[A-Za-z0-9][A-Za-z0-9._-]{0,63}\z/)
    |> validate_length(:title, max: 255)
    |> reject_unknown(attrs, ~w(key title description repo_id))
  end

  def reject_unknown(changeset, attrs, allowed) do
    case Enum.map(Map.keys(attrs), &to_string/1) -- allowed do
      [] -> changeset
      keys -> add_error(changeset, :base, "unsupported fields: #{Enum.join(keys, ", ")}")
    end
  end
end
