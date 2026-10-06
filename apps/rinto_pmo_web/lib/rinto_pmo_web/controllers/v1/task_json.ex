defmodule RintoPMOWeb.V1.TaskJSON do
  alias RintoPMO.Tasks.Task

  def sync(%{result: result}) do
    %{
      data: %{
        document_id: result.document_id,
        revision_id: result.revision_id,
        items:
          Enum.map(result.items, fn item ->
            %{key: item.key, action: item.action, task: data(item.task)}
          end)
      }
    }
  end

  def index(%{tasks: tasks}) do
    %{data: Enum.map(tasks, &data/1)}
  end

  def show(%{task: task}) do
    %{data: data(task)}
  end

  @doc """
  Both ends of a task's dependency edges.

  `depends_on` is what it waits for; `dependents` is what waits for it. A
  prerequisite that is `done` or `cancelled` still appears -- the edge is
  still a true statement about the work -- but holds nothing up, which the
  reader can see from its `status`.
  """
  def dependencies(%{depends_on: depends_on, dependents: dependents}) do
    %{
      data: %{
        depends_on: Enum.map(depends_on, &data/1),
        dependents: Enum.map(dependents, &data/1)
      }
    }
  end

  @doc """
  Every edge, as two ids.

  Nothing about the tasks themselves: this is drawn beside a list that already
  carries them, and repeating a task per edge it appears in would send the
  same rows several times over to say what the client has in hand.
  """
  def edges(%{edges: edges}) do
    %{data: Enum.map(edges, &%{task_id: &1.task_id, depends_on_id: &1.depends_on_id})}
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

  def data(%Task{} = task) do
    %{
      id: task.id,
      project_id: task.project_id,
      requirement_id: task.requirement_id,
      repo_id: task.repo_id,
      document_id: task.document_id,
      assignee_id: task.assignee_id,
      title: task.title,
      description: task.description,
      status: task.status,
      due_on: task.due_on,
      estimate: estimate(task),
      difficulty: task.difficulty,
      actual_minutes: task.actual_minutes,
      planned_start_on: task.planned_start_on,
      first_planned_on: task.first_planned_on,
      priority: task.priority,
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
