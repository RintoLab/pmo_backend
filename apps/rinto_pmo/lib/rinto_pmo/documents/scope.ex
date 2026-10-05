defmodule RintoPMO.Documents.Scope do
  @moduledoc "Document purpose and requirement scope, shared by browsing and semantic recall."
  import Ecto.Query
  alias RintoPMO.Documents.Document

  def parse(params) do
    with {:ok, kind} <- kind(params["kind"]),
         {:ok, requirement} <- requirement(params["requirement_id"]) do
      {:ok, %{} |> put_present(:kind, kind) |> put_present(:requirement_id, requirement)}
    end
  end

  def apply(query, filters) do
    filters = Map.new(filters)

    query =
      case Map.get(filters, :requirement_id) do
        "all" -> query
        value when value in [nil, "none"] -> where(query, [document: d], is_nil(d.requirement_id))
        id -> where(query, [document: d], d.requirement_id == ^id)
      end

    case Map.get(filters, :kind) do
      nil -> query
      kind -> where(query, [document: d], d.kind == ^kind)
    end
  end

  defp kind(nil), do: {:ok, nil}

  defp kind(value) do
    case Enum.find(Document.kinds(), &(Atom.to_string(&1) == value)) do
      nil -> {:error, :bad_request, %{kind: ["is invalid"]}}
      kind -> {:ok, kind}
    end
  end

  defp requirement(value) when value in [nil, "none", "all"], do: {:ok, value}

  defp requirement(value) do
    case Ecto.UUID.cast(value) do
      {:ok, id} -> {:ok, id}
      :error -> {:error, :bad_request, %{requirement_id: ["is invalid"]}}
    end
  end

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)
end
