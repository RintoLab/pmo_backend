defmodule RintoPMO.Requirements.Workload do
  @moduledoc "Read-time task estimates for a requirement and all its descendants. No independent requirement estimate is stored."
  import Ecto.Query
  alias RintoPMO.Repo
  alias RintoPMO.Requirements.Tree
  alias RintoPMO.Tasks.Task

  def load([]), do: []

  def load(requirements) when is_list(requirements) do
    project_ids = requirements |> Enum.map(& &1.project_id) |> Enum.uniq()
    tree = Tree.load(project_ids)
    leaves = Tree.leaf_ids(tree)
    rows = rows(project_ids)

    Enum.map(requirements, fn requirement ->
      ids = MapSet.new(Tree.descendants(tree, [requirement.id]))
      open_ids = MapSet.new(Tree.descendants(tree, [requirement.id], true))
      scoped = Enum.filter(rows, &MapSet.member?(ids, &1.requirement_id))
      planned = MapSet.new(scoped, & &1.requirement_id)

      unplanned =
        Enum.count(tree, fn item ->
          MapSet.member?(open_ids, item.id) and MapSet.member?(leaves, item.id) and
            Tree.open?(item) and not MapSet.member?(planned, item.id)
        end)

      %{requirement | workload: summary(scoped, unplanned)}
    end)
  end

  def load(requirement), do: [requirement] |> load() |> hd()

  defp rows(project_ids) do
    Repo.all(
      from task in Task,
        where: task.project_id in ^project_ids,
        group_by: [task.requirement_id, task.status],
        select: %{
          requirement_id: task.requirement_id,
          status: task.status,
          count: count(task.id),
          optimistic: sum(task.estimate_optimistic),
          likely: sum(task.estimate_likely),
          pessimistic: sum(task.estimate_pessimistic),
          missing: filter(count(task.id), is_nil(task.estimate_optimistic))
        }
    )
  end

  defp summary(rows, unplanned) do
    remaining = Enum.filter(rows, &(&1.status in [:open, :in_progress]))

    %{
      task_count: Enum.sum_by(rows, & &1.count),
      remaining_task_count: Enum.sum_by(remaining, & &1.count),
      unplanned_requirement_count: unplanned,
      estimate: %{
        total: estimate(rows),
        remaining: estimate(remaining),
        unestimated_tasks: Enum.sum_by(rows, & &1.missing),
        unestimated_tasks_remaining: Enum.sum_by(remaining, & &1.missing)
      }
    }
  end

  defp estimate(rows) do
    known = Enum.reject(rows, &is_nil(&1.optimistic))

    if known != [] do
      optimistic = Enum.sum_by(known, & &1.optimistic)
      likely = Enum.sum_by(known, & &1.likely)
      pessimistic = Enum.sum_by(known, & &1.pessimistic)

      %{
        optimistic: optimistic,
        likely: likely,
        pessimistic: pessimistic,
        expected: round((optimistic + 4 * likely + pessimistic) / 6)
      }
    end
  end
end
