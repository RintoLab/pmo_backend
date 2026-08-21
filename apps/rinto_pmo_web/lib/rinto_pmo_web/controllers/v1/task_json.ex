defmodule RintoPMOWeb.V1.TaskJSON do
  alias RintoPMO.Tasks.Task

  def index(%{tasks: tasks}) do
    %{data: Enum.map(tasks, &data/1)}
  end

  def show(%{task: task}) do
    %{data: data(task)}
  end

  @doc """
  A split, with the children it created alongside the cover it made.

  `children` sits next to `data` rather than inside it: a caller that just
  broke a job into five needs the ids it created, and making it re-list to
  find them would leave a window where it cannot address its own work.
  """
  def split(%{task: task}) do
    %{data: data(task), children: Enum.map(task.children, &data/1)}
  end

  def stats(%{stats: stats}) do
    %{
      data: %{
        total: stats.total,
        unassigned: stats.unassigned,
        overdue: stats.overdue,
        by_status: stats.by_status,
        by_assignee: Enum.map(stats.by_assignee, &assignee_counts/1),
        estimate: stats.estimate,
        actual: stats.actual
      }
    }
  end

  @doc """
  One task, rendered whole.

  There is no trimmed list shape: the WBS needs `parent_id` on every row to
  rebuild the tree, and a client that renders `description` only in a detail
  panel is free to ignore it -- the field costs one round trip either way.

  On a `:summary` row, `status` and `estimate` are the rollup over its
  children, not the inert columns underneath them, and `unestimated_tasks`
  counts the work descendants that sum had to leave out.
  """
  def data(%Task{} = task) do
    %{
      id: task.id,
      project_id: task.project_id,
      parent_id: task.parent_id,
      document_id: task.document_id,
      assignee_id: task.assignee_id,
      kind: task.kind,
      title: task.title,
      description: task.description,
      status: task.status,
      due_on: task.due_on,
      estimate: estimate(task),
      unestimated_tasks: task.unestimated_tasks,
      difficulty: task.difficulty,
      unrated_tasks: task.unrated_tasks,
      actual_minutes: task.actual_minutes,
      unmeasured_tasks: task.unmeasured_tasks,
      assigned_at: task.assigned_at,
      started_at: task.started_at,
      completed_at: task.completed_at,
      inserted_at: task.inserted_at,
      updated_at: task.updated_at
    }
  end

  defp assignee_counts(%{actor_id: actor_id, counts: counts}) do
    %{actor_id: actor_id, counts: counts}
  end

  # One object rather than four flat fields, so that "no estimate" is one null
  # instead of three, and so the write shape matches the read shape.
  defp estimate(%Task{estimate_optimistic: nil}), do: nil

  defp estimate(%Task{} = task) do
    %{
      optimistic: task.estimate_optimistic,
      likely: task.estimate_likely,
      pessimistic: task.estimate_pessimistic,
      expected: Task.expected(task)
    }
  end
end
