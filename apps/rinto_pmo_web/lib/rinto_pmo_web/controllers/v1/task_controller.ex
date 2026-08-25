defmodule RintoPMOWeb.V1.TaskController do
  use RintoPMOWeb, :controller

  alias RintoPMO.Jobs
  alias RintoPMO.Tasks.Task
  alias RintoPMO.Utils
  alias RintoPMOWeb.Plugs.ActorToken
  alias RintoPMOWeb.V1.JobJSON

  @statuses Map.new(Task.statuses(), &{Atom.to_string(&1), &1})
  @kinds Map.new(Task.kinds(), &{Atom.to_string(&1), &1})
  @estimation_kinds %{"difficulty" => :difficulty, "time" => :time}

  # The status machine is exposed one endpoint per event rather than as a
  # settable field. `PATCH {status: "done"}` would let a client invent
  # transitions the domain does not have, and would put completing a task in
  # the same request as fixing its typo.

  def index(conn, %{"project_slug" => project_slug} = params) do
    project = get_project!(project_slug)

    with {:ok, filter} <- task_filter(params) do
      tasks = tasks_context().list_tasks(project, filter)
      render(conn, :index, tasks: tasks)
    end
  end

  def create(conn, %{"project_slug" => project_slug} = params) do
    project = get_project!(project_slug)
    attrs = Map.delete(params, "project_slug")

    with {:ok, task} <- tasks_context().create_task(project, attrs) do
      conn
      |> put_status(:created)
      |> render(:show, task: task)
    end
  end

  @doc """
  Counts for one project's board.
  """
  def stats(conn, %{"project_slug" => project_slug}) do
    project = get_project!(project_slug)

    render(conn, :stats, stats: tasks_context().project_stats(project))
  end

  def show(conn, %{"id" => id}) do
    render(conn, :show, task: tasks_context().get_task!(id))
  end

  def update(conn, %{"id" => id} = params) do
    context = tasks_context()
    task = context.get_task!(id)
    attrs = Map.delete(params, "id")

    with {:ok, task} <- context.update_task(task, attrs) do
      render(conn, :show, task: task)
    end
  end

  @doc """
  What a task is waiting for, and what is waiting for it.

  Both directions in one response: "can I start this" and "what breaks if I
  move it" are the two questions asked of an edge, and a client that had to
  make two calls to see both would draw half a graph.
  """
  def dependencies(conn, %{"id" => id}) do
    context = tasks_context()
    task = context.get_task!(id)

    render(conn, :dependencies,
      depends_on: context.list_dependencies(task),
      dependents: context.list_dependents(task)
    )
  end

  def add_dependency(conn, %{"id" => id} = params) do
    context = tasks_context()
    task = context.get_task!(id)

    with {:ok, _edge} <- context.add_dependency(task, Map.get(params, "depends_on_id")) do
      render(conn, :dependencies,
        depends_on: context.list_dependencies(task),
        dependents: context.list_dependents(task)
      )
    end
  end

  def remove_dependency(conn, %{"id" => id, "depends_on_id" => depends_on_id}) do
    context = tasks_context()
    task = context.get_task!(id)

    with :ok <- context.remove_dependency(task, depends_on_id) do
      send_resp(conn, :no_content, "")
    end
  end

  @doc """
  Hands a task to an actor, overriding whoever held it.
  """
  def assign(conn, %{"id" => id} = params) do
    context = tasks_context()
    task = context.get_task!(id)

    with {:ok, task} <- context.assign_task(task, Map.get(params, "actor_id")) do
      render(conn, :show, task: task)
    end
  end

  @doc """
  Takes an unclaimed task, refusing with 409 when someone else got there first.

  Claiming is pulling, so the claimant is the caller and the body no longer
  says who. Pushing work at somebody else is `assign`, which still names them:
  the difference between the two is exactly whose id is involved.
  """
  def claim(conn, %{"id" => id}) do
    context = tasks_context()
    task = context.get_task!(id)

    with {:ok, task} <- context.claim_task(task, ActorToken.current_actor!(conn).id) do
      render(conn, :show, task: task)
    end
  end

  @doc """
  Puts a task back in the pool without touching its status.
  """
  def release(conn, %{"id" => id}) do
    context = tasks_context()
    task = context.get_task!(id)

    with {:ok, task} <- context.release_task(task) do
      render(conn, :show, task: task)
    end
  end

  @doc """
  Removes a task outright. `cancel` is the one that keeps the record.
  """
  def delete(conn, %{"id" => id}) do
    context = tasks_context()
    task = context.get_task!(id)

    with {:ok, _task} <- context.delete_task(task) do
      send_resp(conn, :no_content, "")
    end
  end

  @doc """
  Turns a job into the cover over the jobs it turned out to be.

  The one thing that moves `kind`. `children` is optional -- the promotion is
  the operation, and existing tasks can be moved under it afterwards.
  """
  def split(conn, %{"id" => id} = params) do
    context = tasks_context()
    task = context.get_task!(id)

    with {:ok, children} <- split_children(params),
         {:ok, summary} <- context.split_task(task, children) do
      render(conn, :split, task: summary)
    end
  end

  @doc """
  Moves a task to `:in_progress`. Refuses when nobody owns it.
  """
  def start(conn, %{"id" => id}), do: transition(conn, id, :start)

  @doc """
  Marks a task done.

  Accepts optional `actual_minutes` so finishing and recording how long it
  took can be one act. Absent or null leaves whatever was already stored.
  """
  def complete(conn, %{"id" => id} = params) do
    transition(conn, id, :complete, Map.take(params, ["actual_minutes"]))
  end

  @doc """
  Abandons a task without deleting it, keeping what was spent on it.
  """
  def cancel(conn, %{"id" => id}), do: transition(conn, id, :cancel)

  @doc """
  Returns a finished or abandoned task to `:open`.
  """
  def reopen(conn, %{"id" => id}), do: transition(conn, id, :reopen)

  @doc """
  Asks a model to fill in what this node is missing.

  One endpoint with a `kind`, unlike the transitions above: those are events on
  a state machine and each one means something different, while these two are
  the same operation asking the model a different question. Everything around
  them -- what is targeted, what is refused, what comes back -- is identical.

  Answers `202` with the *job*, not the numbers: the model call runs in a
  queue. The `id` in that job is an Oban job id and the only handle there is --
  not to be confused with the task id in the path. Keep it, listen on
  `task:{id}` for the result, and ask `GET /jobs/{job_id}` if the connection
  dropped while the model was thinking.
  """
  def estimate(conn, %{"id" => id} = params) do
    context = tasks_context()

    with {:ok, kind} <- estimation_kind(params),
         {:ok, job} <- context.request_estimation(context.get_task!(id), kind) do
      accept_estimation(conn, job)
    end
  end

  # Required rather than defaulted. There is no obvious default between the
  # two, and guessing would spend a model call on the question nobody asked.
  defp estimation_kind(params) do
    case Map.fetch(@estimation_kinds, Map.get(params, "kind")) do
      {:ok, kind} -> {:ok, kind}
      :error -> {:error, :bad_request, %{"kind" => ["is invalid"]}}
    end
  end

  # Answered the same whether this call queued the job or found one already
  # queued: a double-click is one estimation, and a client that gets the same
  # id back twice needs no branch for it.
  defp accept_estimation(conn, job) do
    conn
    |> put_status(:accepted)
    |> put_view(JobJSON)
    |> render(:show, job: Jobs.describe(job))
  end

  defp transition(conn, id, event, attrs \\ %{}) do
    context = tasks_context()
    task = context.get_task!(id)

    with {:ok, task} <- context.transition_task(task, event, attrs) do
      render(conn, :show, task: task)
    end
  end

  defp split_children(params) do
    case Map.get(params, "children") do
      nil -> {:ok, []}
      children when is_list(children) -> validate_children(children)
      _invalid -> {:error, :bad_request, %{"children" => ["must be an array"]}}
    end
  end

  defp validate_children(children) do
    if Enum.all?(children, &is_map/1) do
      {:ok, children}
    else
      {:error, :bad_request, %{"children" => ["each child must be an object"]}}
    end
  end

  defp task_filter(params) do
    with {:ok, filter} <- enum_filter(params, %{}, "kind", :kind, @kinds),
         {:ok, filter} <- enum_filter(params, filter, "status", :status, @statuses),
         {:ok, filter} <- assignee_filter(params, filter),
         {:ok, filter} <- parent_filter(params, filter),
         {:ok, filter} <- document_filter(params, filter),
         {:ok, filter} <- boolean_filter(params, filter, "live", :live) do
      boolean_filter(params, filter, "overdue", :overdue)
    end
  end

  defp enum_filter(params, filter, parameter, key, allowed) do
    case Map.get(params, parameter) do
      nil ->
        {:ok, filter}

      value ->
        case Map.fetch(allowed, value) do
          {:ok, parsed} -> {:ok, Map.put(filter, key, parsed)}
          :error -> {:error, :bad_request, %{parameter => ["is invalid"]}}
        end
    end
  end

  # `parent_id=none` is the set of roots -- the top level of the WBS. Like
  # `assignee_id`, it has to be spelled, because absent means "no filter".
  defp parent_filter(params, filter) do
    case Map.get(params, "parent_id") do
      nil -> {:ok, filter}
      "none" -> {:ok, Map.put(filter, :parent_id, nil)}
      value -> uuid_filter(value, filter, :parent_id, "parent_id")
    end
  end

  # `assignee_id=none` is the claimable pool. It has to be spelled rather than
  # left as an absent parameter, because absent already means "no filter".
  defp assignee_filter(params, filter) do
    case Map.get(params, "assignee_id") do
      nil -> {:ok, filter}
      "none" -> {:ok, Map.put(filter, :assignee_id, nil)}
      value -> uuid_filter(value, filter, :assignee_id, "assignee_id")
    end
  end

  defp document_filter(params, filter) do
    case Map.get(params, "document_id") do
      nil -> {:ok, filter}
      value -> uuid_filter(value, filter, :document_id, "document_id")
    end
  end

  defp uuid_filter(value, filter, key, parameter) do
    case UUIDv7.cast(value) do
      {:ok, id} -> {:ok, Map.put(filter, key, id)}
      :error -> {:error, :bad_request, %{parameter => ["is invalid"]}}
    end
  end

  defp boolean_filter(params, filter, parameter, key) do
    case Map.get(params, parameter) do
      nil -> {:ok, filter}
      "true" -> {:ok, Map.put(filter, key, true)}
      "false" -> {:ok, Map.put(filter, key, false)}
      _invalid -> {:error, :bad_request, %{parameter => ["is invalid"]}}
    end
  end

  defp get_project!(project_slug),
    do: Utils.module(:projects).get_active_project_by_slug!(project_slug)

  defp tasks_context, do: Utils.module(:tasks)
end
