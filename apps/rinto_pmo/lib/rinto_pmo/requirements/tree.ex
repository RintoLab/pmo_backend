defmodule RintoPMO.Requirements.Tree do
  @moduledoc false
  import Ecto.Query
  alias RintoPMO.Repo
  alias RintoPMO.Requirements.Requirement

  def load(project_ids) do
    Repo.all(from requirement in Requirement, where: requirement.project_id in ^project_ids)
  end

  def descendants(requirements, ids, open_only? \\ false) do
    by_id = Map.new(requirements, &{&1.id, &1})
    children = Enum.group_by(requirements, & &1.parent_id, & &1.id)
    walk(ids, by_id, children, %{}, open_only?) |> Map.keys() |> Enum.sort()
  end

  def open?(requirement),
    do: is_nil(requirement.archived_at) and requirement.status in [:draft, :analyzed, :active]

  def leaf_ids(requirements) do
    parents = requirements |> Enum.filter(&is_nil(&1.archived_at)) |> MapSet.new(& &1.parent_id)
    requirements |> Enum.reject(&MapSet.member?(parents, &1.id)) |> MapSet.new(& &1.id)
  end

  def ancestry(requirements, id), do: ancestors(Map.new(requirements, &{&1.id, &1}), id, [])

  defp ancestors(_by_id, nil, acc), do: acc

  defp ancestors(by_id, id, acc) do
    requirement = Map.fetch!(by_id, id)
    ancestors(by_id, requirement.parent_id, [requirement | acc])
  end

  defp walk([], _by_id, _children, visited, _open_only?), do: visited

  defp walk([id | rest], by_id, children, visited, open_only?) do
    if Map.has_key?(visited, id) or (open_only? and not open?(Map.fetch!(by_id, id))) do
      walk(rest, by_id, children, visited, open_only?)
    else
      walk(
        Map.get(children, id, []) ++ rest,
        by_id,
        children,
        Map.put(visited, id, true),
        open_only?
      )
    end
  end
end
