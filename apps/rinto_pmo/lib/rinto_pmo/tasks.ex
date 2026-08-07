defmodule RintoPMO.Tasks do
  @moduledoc """
  The context for a project's work breakdown: its structure, its distribution,
  and its counts.

  ## Structure

  One tree of one resource. A summary node is a task row with `kind: :summary`,
  and it is a cover over work rather than work itself: it takes no assignee and
  no transitions, and its status is `RintoPMO.Tasks.Task.rollup/1` over its
  children.

  That rollup is *derived at read time*, never stored. A cached status would
  have to be recomputed on every transition of every descendant, and the first
  path that forgot would leave a chunk claiming to be done over children that
  are not. The stored `status` column on a `:summary` row is inert; every read
  in this module overwrites it.

  `kind` moves both ways, and never as a field a client writes. Up through
  `split_task/2` when a job turns out to be several; down automatically the
  moment a cover loses its last child, because the two ways to empty one --
  deleting a child, or moving it elsewhere -- both leave a node that can
  neither be worked nor roll anything up.

  ## Distribution

  Two ways in, one field out. `assign_task/2` is a PM pushing work at someone;
  `claim_task/2` is an actor -- a developer, or the pi CLI on one's behalf --
  pulling from the pool. Both land in `assignee_id`, so nothing downstream has
  to know which happened.

  The difference between them is who may lose. Assigning is authoritative and
  overwrites whoever held it. Claiming is a race between equals, so it is a
  single conditional `UPDATE ... WHERE assignee_id IS NULL`, and the loser is
  told it lost rather than quietly stealing the task. Reading first and writing
  second would hand the same task to two agents under any real concurrency.

  ## Estimates

  Three-point, in minutes, and never written as raw columns: `estimate` comes
  in as one object so that "all three or none" and "optimistic <= likely <=
  pessimistic" can be checked as one thing and refused as `invalid_estimate`.
  A cover's estimate is the sum over its descendants, rolled up on read exactly
  like its status, and carries a count of the descendants it had to skip so a
  partial sum can never pass for a whole one.

  ## Counts

  `project_stats/1` counts work, not covers. A summary node is its children
  restated, so counting it would tally every job twice and inflate a board's
  totals by however finely someone chose to break the project down.
  """

  use RintoPMO, :context

  alias Ecto.Changeset
  alias RintoPMO.Actors.Actor
  alias RintoPMO.Projects.Project
  alias RintoPMO.Tasks.Task

  # A parent chain deeper than this is a corrupt tree, not a breakdown. The
  # bound exists so a cycle written by some future path fails loudly here
  # instead of spinning.
  @max_depth 64

  defmodule Behaviour do
    @moduledoc false

    alias RintoPMO.Projects.Project
    alias RintoPMO.Tasks.Task

    @type filter :: %{
            optional(:kind) => Task.kind(),
            optional(:status) => Task.status(),
            optional(:assignee_id) => UUIDv7.t() | nil,
            optional(:document_id) => UUIDv7.t(),
            optional(:parent_id) => UUIDv7.t() | nil,
            optional(:live) => boolean(),
            optional(:overdue) => boolean()
          }

    @type estimate :: %{
            optimistic: non_neg_integer(),
            likely: non_neg_integer(),
            pessimistic: non_neg_integer(),
            expected: non_neg_integer()
          }

    @type stats :: %{
            total: non_neg_integer(),
            unassigned: non_neg_integer(),
            overdue: non_neg_integer(),
            by_status: %{Task.status() => non_neg_integer()},
            by_assignee: [
              %{actor_id: UUIDv7.t(), counts: %{Task.status() => non_neg_integer()}}
            ],
            estimate: %{
              total: estimate() | nil,
              remaining: estimate() | nil,
              unestimated_tasks: non_neg_integer(),
              unestimated_tasks_remaining: non_neg_integer()
            }
          }

    @typedoc """
    A refusal the API layer turns into an `error` code rather than a field-level
    validation message. The shape `RintoPMOWeb.FallbackController` understands.
    """
    @type refusal :: {:error, atom()} | {:error, atom(), map()}

    @callback list_tasks(Project.t(), filter()) :: [Task.t()]
    @callback get_task!(UUIDv7.t()) :: Task.t()
    @callback create_task(Project.t(), map()) ::
                {:ok, Task.t()} | {:error, Ecto.Changeset.t()} | refusal()
    @callback update_task(Task.t(), map()) ::
                {:ok, Task.t()} | {:error, Ecto.Changeset.t()} | refusal()

    @callback assign_task(Task.t(), term()) ::
                {:ok, Task.t()} | {:error, Ecto.Changeset.t()} | refusal()
    @callback claim_task(Task.t(), term()) ::
                {:ok, Task.t()} | {:error, Ecto.Changeset.t()} | refusal()
    @callback release_task(Task.t()) ::
                {:ok, Task.t()} | {:error, Ecto.Changeset.t()} | refusal()

    @callback transition_task(Task.t(), Task.event()) ::
                {:ok, Task.t()} | {:error, Ecto.Changeset.t()} | refusal()

    @callback split_task(Task.t(), [map()]) ::
                {:ok, Task.t()} | {:error, Ecto.Changeset.t()} | refusal()

    @callback delete_task(Task.t()) ::
                {:ok, Task.t()} | {:error, Ecto.Changeset.t()} | refusal()

    @callback project_stats(Project.t()) :: stats()
  end

  @behaviour Behaviour

  @doc """
  Lists a project's tasks, oldest first, with summary nodes rolled up.

  Ascending order, unlike annotations and conversations: a backlog is worked
  from the front, and the oldest outstanding task is the one that has been
  waiting longest. Flat order, not tree order -- `parent_id` is on every row,
  so a client that wants the WBS shape builds it once and keeps it, while a
  client that wants a queue is not made to unpick a tree first.

  The project is read whole and filtered in memory, because a summary's status
  depends on children a `WHERE` clause may have just excluded: filtering in SQL
  would make `?status=done` hide exactly the children that decide whether the
  cover above them is done. Lists here are unpaginated by design, so this reads
  no more rows than the unfiltered call already did.
  """
  @impl true
  def list_tasks(%Project{} = project, filter) when is_map(filter) do
    project.id
    |> project_tasks()
    |> filter_tasks(filter)
  end

  @doc """
  Fetches a task by id, raising when it does not exist.

  Not scoped through a project: a task id is enough to name one, and the CLI
  that picked a task out of the pool has the id and not the project slug.
  """
  @impl true
  def get_task!(id) do
    case Repo.get!(Task, id) do
      %Task{kind: :work} = task ->
        task

      %Task{kind: :summary} = task ->
        task.project_id
        |> project_tasks()
        |> Enum.find(task, &(&1.id == task.id))
    end
  end

  @doc """
  Creates a task under a project.

  It starts `:open`, with or without an assignee -- creating work and deciding
  whose it is are separate acts, and a PM filing a backlog does only the first.
  Pass `kind: "summary"` for a cover node; `kind` cannot be changed afterwards.
  """
  @impl true
  def create_task(%Project{} = project, attrs) do
    with {:ok, attrs} <- put_estimate(attrs) do
      chset = Task.creation_changeset(%Task{project_id: project.id}, attrs)

      with {:ok, chset} <- validate_parent(chset, project.id, nil) do
        Repo.insert(chset)
      end
    end
  end

  @doc """
  Updates a task's wording, spec pointer, place in the tree, owner, or due date.

  Neither `status` nor `kind` is accepted here. Status moves only through
  `transition_task/2`; `kind` never moves at all.
  """
  @impl true
  def update_task(%Task{} = task, attrs) do
    with {:ok, attrs} <- put_estimate(attrs, task.kind) do
      chset = Task.changeset(task, attrs)

      with {:ok, chset} <- validate_parent(chset, task.project_id, task.id) do
        Repo.transact(&apply_move(&1, chset, task.parent_id))
      end
    end
  end

  defp apply_move(repo, chset, old_parent_id) do
    with {:ok, updated} <- repo.update(chset) do
      demote_if_emptied(repo, old_parent_id, updated.parent_id)
      {:ok, updated}
    end
  end

  @doc """
  Deletes a task outright.

  The one place in this domain where something is really removed. `cancel` is
  the record that work was dropped and stays in the tree; delete is for rows
  that should never have been there -- a breakdown an agent got wrong, filed
  and rejected in the same sitting.

  Refuses a node that still has children rather than scattering them: the
  foreign key would silently reparent them to the root, and a WBS quietly
  flattening itself is worse than being told to empty the cover first.

  Deleting the last child of a cover demotes that cover back to a job.
  """
  @impl true
  def delete_task(%Task{} = task) do
    Repo.transact(&remove(&1, task))
    |> unwrap_refusal()
  end

  defp remove(repo, %Task{} = task) do
    if child_count(repo, task.id) > 0 do
      {:error, {:task_state_conflict, %{kind: task.kind, reason: "task still has children"}}}
    else
      detach(repo, task)
    end
  end

  defp detach(repo, %Task{} = task) do
    with {:ok, deleted} <- repo.delete(task) do
      demote_if_emptied(repo, task.parent_id, nil)
      {:ok, deleted}
    end
  end

  @doc """
  Assigns a task to an actor, overwriting any current assignee.

  The authoritative half of distribution: a PM reassigning does not have to
  release first, because a handoff is one decision and should not be able to
  half-happen.
  """
  @impl true
  def assign_task(%Task{} = task, actor_id) do
    with :ok <- require_work(task),
         {:ok, actor_id} <- validate_assignee(actor_id) do
      task
      |> Task.assignment_changeset(actor_id)
      |> Repo.update()
    end
  end

  @doc """
  Claims an unassigned, unfinished task for an actor.

  Returns `{:error, :task_already_claimed, details}` when someone else got
  there first, and `{:error, :task_state_conflict, details}` when the task is
  finished or is a summary node. The check and the write are one statement, so
  two agents claiming at once produce one winner and one refusal rather than
  two winners.
  """
  @impl true
  def claim_task(%Task{} = task, actor_id) do
    with :ok <- require_work(task),
         {:ok, actor_id} <- validate_assignee(actor_id) do
      now = DateTime.utc_now()
      live_statuses = Task.live_statuses()

      claimed =
        Task
        |> where([candidate], candidate.id == ^task.id)
        |> where([candidate], candidate.kind == :work)
        |> where([candidate], is_nil(candidate.assignee_id))
        |> where([candidate], candidate.status in ^live_statuses)
        |> select([candidate], candidate)
        |> Repo.update_all(set: [assignee_id: actor_id, assigned_at: now, updated_at: now])

      case claimed do
        {1, [task]} -> {:ok, task}
        {0, _none} -> claim_refusal(task.id)
      end
    end
  end

  @doc """
  Returns a task to the pool, leaving its status alone.

  Releasing is not cancelling: the work still needs doing, it just needs doing
  by someone else. A released `:in_progress` task keeps `started_at`, so the
  next actor inherits an honest record of how long it has been open rather
  than a clock reset to hide the handoff.
  """
  @impl true
  def release_task(%Task{} = task) do
    with :ok <- require_work(task) do
      task
      |> Task.assignment_changeset(nil)
      |> Repo.update()
    end
  end

  @doc """
  Moves a task through the status machine.

  Refuses with `{:error, :task_state_conflict, details}` when the event does
  not apply to the current status, when the task is a summary node whose status
  is not its own to move, or when `:start` is asked of a task nobody owns --
  starting work with no owner is how a task ends up in progress with nobody on
  it.
  """
  @impl true
  def transition_task(%Task{} = task, event) do
    with :ok <- require_work(task),
         {:ok, _next} <- allowed_transition(task, event),
         :ok <- require_assignee(task, event) do
      task
      |> Task.transition_changeset(event)
      |> Repo.update()
    end
  end

  @doc """
  Turns a job into the cover over the jobs it turned out to be.

  This is the one thing that moves `kind`, and it moves in one direction. A
  breakdown discovers that a task is really several, and refusing that would
  refuse what a WBS is for -- but it is an operation rather than a field,
  because the flip drops the assignee and the clocks, and that should never
  ride along with an edit of the wording.

  Refuses a task that is already a cover, and one that is `:done` or
  `:cancelled`: a finished job is not a container for unfinished work, and
  promoting it would leave a `completed_at` claiming a chunk was delivered
  before anyone knew what was in it.

  `children` may be empty. The promotion is the operation; a cover with nothing
  under it reads `:open`, which is exactly true -- nobody has broken it down
  yet -- and existing tasks can be moved in afterwards with `update_task/2`.
  Everything here happens in one transaction, so a split never half-lands.
  """
  @impl true
  def split_task(task, children \\ [])

  def split_task(%Task{kind: :summary} = task, _children) do
    {:error, :task_not_splittable, %{kind: :summary, current_status: task.status}}
  end

  def split_task(%Task{status: status} = task, _children)
      when status in [:done, :cancelled] do
    {:error, :task_not_splittable, %{kind: task.kind, current_status: status}}
  end

  def split_task(%Task{} = task, children) when is_list(children) do
    Repo.transact(fn repo ->
      with {:ok, summary} <- repo.update(Task.split_changeset(task)),
           {:ok, inserted} <- insert_children(summary, children, repo) do
        {:ok, %{summary | children: inserted}}
      end
    end)
    |> unwrap_refusal()
  end

  # `Repo.transact/1` only speaks two-tuples, so a refusal travels wrapped and
  # is unpacked here rather than being flattened into a changeset it is not.
  defp unwrap_refusal({:error, {code, details}}), do: {:error, code, details}
  defp unwrap_refusal(result), do: result

  defp insert_children(%Task{} = summary, children, repo) do
    children
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {attrs, index}, {:ok, acc} ->
      case insert_child(summary, attrs, repo) do
        {:ok, child} -> {:cont, {:ok, [child | acc]}}
        {:error, chset} -> {:halt, {:error, {:validation_error, child_errors(index, chset)}}}
        {:error, code, details} -> {:halt, {:error, {code, Map.put(details, :child, index)}}}
      end
    end)
    |> case do
      {:ok, inserted} -> {:ok, Enum.reverse(inserted)}
      error -> error
    end
  end

  # Children go through the same estimate gate as any other write. Handing
  # `Task.changeset/2` the raw attrs would make `estimate_likely` castable
  # here and nowhere else, which is exactly the hole an agent generating a
  # breakdown would fall into.
  defp insert_child(%Task{} = summary, attrs, repo) do
    with {:ok, attrs} <- put_estimate(attrs) do
      %Task{project_id: summary.project_id, parent_id: summary.id}
      |> Task.changeset(attrs)
      |> repo.insert()
    end
  end

  # Which child failed matters: a caller that sent five of them -- an agent
  # that just generated a breakdown, say -- cannot act on "title is blank"
  # without knowing whose title.
  defp child_errors(index, chset) do
    translated =
      Changeset.traverse_errors(chset, fn {message, opts} ->
        Regex.replace(~r"%{(\w+)}", message, fn _whole, key ->
          opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
        end)
      end)

    %{"children" => %{Integer.to_string(index) => translated}}
  end

  @doc """
  Counts a project's work by status and by assignee.

  Summary nodes are excluded from every number here. A cover is its children
  restated, so counting it would tally each job twice and make a board's totals
  a function of how finely someone chose to break the project down.

  `by_status` always carries every status, including the ones at zero: a board
  that hides its empty columns changes shape as work moves through it.
  `by_assignee` covers only actors that hold at least one task, and excludes
  the unassigned -- those are their own number, not an actor with a null id.
  """
  @impl true
  def project_stats(%Project{} = project) do
    rows =
      project
      |> work_tasks()
      |> group_by([task], [task.status, task.assignee_id])
      |> select([task], %{
        status: task.status,
        assignee_id: task.assignee_id,
        count: count(task.id),
        optimistic: sum(task.estimate_optimistic),
        likely: sum(task.estimate_likely),
        pessimistic: sum(task.estimate_pessimistic),
        unestimated_tasks: filter(count(task.id), is_nil(task.estimate_optimistic))
      })
      |> Repo.all()

    %{
      total: Enum.sum_by(rows, & &1.count),
      unassigned: rows |> Enum.filter(&is_nil(&1.assignee_id)) |> Enum.sum_by(& &1.count),
      overdue: count_overdue(project),
      by_status: by_status(rows),
      by_assignee: by_assignee(rows),
      estimate: estimate_stats(rows)
    }
  end

  # Two totals, because they answer different questions: `total` is what the
  # project was ever thought to be worth, `remaining` is what is left. Both
  # ship with a count of the tasks they had to leave out -- a sum over half
  # the backlog reads exactly like a sum over all of it, and only the count
  # tells them apart. The count is of *tasks*, hence the name: everything else
  # in this block is minutes, and a bare `unestimated` read as one.
  defp estimate_stats(rows) do
    live_statuses = Task.live_statuses()
    remaining = Enum.filter(rows, &(&1.status in live_statuses))

    %{
      total: sum_estimate(rows),
      remaining: sum_estimate(remaining),
      unestimated_tasks: Enum.sum_by(rows, & &1.unestimated_tasks),
      unestimated_tasks_remaining: Enum.sum_by(remaining, & &1.unestimated_tasks)
    }
  end

  defp sum_estimate(rows) do
    optimistic = rows |> Enum.map(& &1.optimistic) |> sum_present()

    if optimistic do
      likely = rows |> Enum.map(& &1.likely) |> sum_present()
      pessimistic = rows |> Enum.map(& &1.pessimistic) |> sum_present()

      %{
        optimistic: optimistic,
        likely: likely,
        pessimistic: pessimistic,
        expected: round((optimistic + 4 * likely + pessimistic) / 6)
      }
    end
  end

  # Nil when nothing in the set carried an estimate, so that "nobody estimated
  # this" never renders as "this costs nothing".
  defp sum_present(values) do
    case Enum.reject(values, &is_nil/1) do
      [] -> nil
      present -> Enum.sum(present)
    end
  end

  defp by_status(rows) do
    zeroes = Map.new(Task.statuses(), &{&1, 0})

    Enum.reduce(rows, zeroes, fn row, acc -> Map.update!(acc, row.status, &(&1 + row.count)) end)
  end

  defp by_assignee(rows) do
    zeroes = Map.new(Task.statuses(), &{&1, 0})

    rows
    |> Enum.reject(&is_nil(&1.assignee_id))
    |> Enum.group_by(& &1.assignee_id, &{&1.status, &1.count})
    |> Enum.map(fn {actor_id, counts} ->
      %{actor_id: actor_id, counts: Enum.into(counts, zeroes)}
    end)
    |> Enum.sort_by(& &1.actor_id)
  end

  # Overdue is a property of work still outstanding. A task delivered late was
  # late; it is not still late, and counting it forever would make the number
  # only ever grow.
  defp count_overdue(%Project{} = project) do
    live_statuses = Task.live_statuses()
    today = Date.utc_today()

    project
    |> work_tasks()
    |> where([task], task.status in ^live_statuses)
    |> where([task], not is_nil(task.due_on) and task.due_on < ^today)
    |> Repo.aggregate(:count, :id)
  end

  defp work_tasks(%Project{} = project) do
    Task
    |> where([task], task.project_id == ^project.id)
    |> where([task], task.kind == :work)
  end

  # A cover is a cover over something. The moment the last child leaves -- by
  # deletion or by being moved elsewhere -- there is nothing left to cover, and
  # the node would otherwise sit in the tree unable to be worked and with
  # nothing to roll up.
  #
  # Not fired for a cover that never had children: creating one top-down, or
  # splitting with an empty payload, is a breakdown that has not been filled in
  # yet, and demoting it would undo the intent in the same breath as recording
  # it. This is a rule about *emptying*, not about being empty.
  defp demote_if_emptied(_repo, nil, _new_parent_id), do: :ok
  defp demote_if_emptied(_repo, same, same), do: :ok

  defp demote_if_emptied(repo, old_parent_id, _new_parent_id) do
    with %Task{kind: :summary} = parent <- repo.get(Task, old_parent_id),
         0 <- child_count(repo, old_parent_id) do
      {:ok, _demoted} = repo.update(Task.demote_changeset(parent))
      :ok
    else
      _still_covering -> :ok
    end
  end

  defp child_count(repo, task_id) do
    Task
    |> where([task], task.parent_id == ^task_id)
    |> repo.aggregate(:count, :id)
  end

  # ---------------------------------------------------------------- rollup

  defp project_tasks(project_id) do
    tasks =
      Task
      |> where([task], task.project_id == ^project_id)
      |> order_by([task], asc: task.id)
      |> Repo.all()

    children = Enum.group_by(tasks, & &1.parent_id)

    Enum.map(tasks, &roll_up(&1, children, []))
  end

  defp roll_up(%Task{kind: :work} = task, _children, _ancestors), do: task

  defp roll_up(%Task{kind: :summary} = task, children, ancestors) do
    if task.id in ancestors do
      # Only reachable if a cycle survived `validate_parent/3`. Yielding the
      # row untouched breaks the loop rather than recursing forever.
      task
    else
      rolled =
        children
        |> Map.get(task.id, [])
        |> Enum.map(&roll_up(&1, children, [task.id | ancestors]))

      %{
        task
        | status: rolled |> Enum.map(& &1.status) |> Task.rollup(),
          unestimated_tasks: Enum.sum_by(rolled, &count_unestimated/1)
      }
      |> put_summed_estimate(rolled)
    end
  end

  defp count_unestimated(%Task{kind: :summary} = task), do: task.unestimated_tasks
  defp count_unestimated(%Task{estimate_optimistic: nil}), do: 1
  defp count_unestimated(%Task{}), do: 0

  # Summed over the descendants that actually carry one. A cover with nothing
  # estimated under it reports no estimate rather than zero: zero is a claim
  # that the chunk is free, and nobody made it.
  defp put_summed_estimate(%Task{} = task, rolled) do
    case Enum.reject(rolled, &is_nil(&1.estimate_optimistic)) do
      [] ->
        task

      estimated ->
        %{
          task
          | estimate_optimistic: Enum.sum_by(estimated, & &1.estimate_optimistic),
            estimate_likely: Enum.sum_by(estimated, & &1.estimate_likely),
            estimate_pessimistic: Enum.sum_by(estimated, & &1.estimate_pessimistic)
        }
    end
  end

  # ---------------------------------------------------------------- filtering

  defp filter_tasks(tasks, filter) do
    live_statuses = Task.live_statuses()
    today = Date.utc_today()

    Enum.filter(tasks, fn task ->
      Enum.all?(filter, fn
        {:kind, kind} -> task.kind == kind
        {:status, status} -> task.status == status
        {:assignee_id, assignee_id} -> task.assignee_id == assignee_id
        {:document_id, document_id} -> task.document_id == document_id
        {:parent_id, parent_id} -> task.parent_id == parent_id
        {:live, live} -> task.status in live_statuses == live
        {:overdue, overdue} -> overdue?(task, live_statuses, today) == overdue
        {_other, _value} -> true
      end)
    end)
  end

  defp overdue?(%Task{due_on: nil}, _live_statuses, _today), do: false

  defp overdue?(%Task{} = task, live_statuses, today) do
    task.status in live_statuses and Date.before?(task.due_on, today)
  end

  # ---------------------------------------------------------------- estimates

  @estimate_fields ~w(optimistic likely pessimistic)
  @estimate_columns ~w(estimate_optimistic estimate_likely estimate_pessimistic)

  # The three columns are never castable from the request. They arrive as one
  # `estimate` object, get checked as one thing, and are written back flat --
  # otherwise a client could set `estimate_likely` alone and slip past every
  # rule about the shape being whole and ordered.
  defp put_estimate(attrs, kind \\ :work) do
    attrs = attrs |> stringify_keys() |> Map.drop(@estimate_columns)

    case Map.fetch(attrs, "estimate") do
      :error -> {:ok, attrs}
      {:ok, nil} -> {:ok, Map.merge(attrs, clear_estimate())}
      {:ok, _estimate} when kind == :summary -> {:error, :invalid_estimate, summary_refusal()}
      {:ok, estimate} -> cast_estimate(attrs, estimate)
    end
  end

  defp summary_refusal do
    %{field: "estimate", reason: "a summary node takes its estimate from its children"}
  end

  defp clear_estimate, do: Map.new(@estimate_columns, &{&1, nil})

  defp cast_estimate(attrs, estimate) when is_map(estimate) do
    estimate = stringify_keys(estimate)

    with {:ok, values} <- fetch_estimate_values(estimate),
         :ok <- validate_estimate_order(values) do
      flat = Map.new(values, fn {field, value} -> {"estimate_" <> field, value} end)
      {:ok, Map.merge(attrs, flat)}
    end
  end

  defp cast_estimate(_attrs, _estimate) do
    {:error, :invalid_estimate, %{field: "estimate", reason: "must be an object or null"}}
  end

  defp fetch_estimate_values(estimate) do
    Enum.reduce_while(@estimate_fields, {:ok, []}, fn field, {:ok, acc} ->
      case Map.get(estimate, field) do
        value when is_integer(value) and value >= 0 ->
          {:cont, {:ok, [{field, value} | acc]}}

        nil ->
          {:halt, estimate_error(field, "must be given with optimistic, likely, and pessimistic")}

        _invalid ->
          {:halt, estimate_error(field, "must be a non-negative whole number of minutes")}
      end
    end)
    |> case do
      {:ok, values} -> {:ok, Enum.reverse(values)}
      error -> error
    end
  end

  defp validate_estimate_order([{_, optimistic}, {_, likely}, {_, pessimistic}]) do
    cond do
      optimistic > likely -> estimate_error("likely", "must be ordered")
      likely > pessimistic -> estimate_error("pessimistic", "must be ordered")
      true -> :ok
    end
  end

  defp estimate_error(field, reason) do
    {:error, :invalid_estimate, %{field: field, reason: reason}}
  end

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {to_string(key), value} end)
  end

  # ---------------------------------------------------------------- parenting

  # A parent has to be a summary node in the same project, and it must not sit
  # underneath the task it is being given. The first two are field errors; the
  # cycle is not -- nothing about the submitted value is malformed, the tree
  # simply cannot hold that shape, which is what `dependency_cycle` says.
  defp validate_parent(chset, project_id, task_id) do
    case Changeset.fetch_change(chset, :parent_id) do
      :error -> {:ok, chset}
      {:ok, nil} -> {:ok, chset}
      {:ok, parent_id} -> validate_parent_id(chset, parent_id, project_id, task_id)
    end
  end

  defp validate_parent_id(chset, parent_id, project_id, task_id) do
    case Repo.get(Task, parent_id) do
      nil ->
        {:ok, Changeset.add_error(chset, :parent_id, "does not exist")}

      %Task{project_id: other} when other != project_id ->
        {:ok, Changeset.add_error(chset, :parent_id, "belongs to another project")}

      %Task{kind: :work} ->
        {:ok, Changeset.add_error(chset, :parent_id, "must be a summary node")}

      %Task{} = parent ->
        detect_cycle(chset, parent, task_id)
    end
  end

  defp detect_cycle(chset, _parent, nil), do: {:ok, chset}

  defp detect_cycle(chset, %Task{} = parent, task_id) do
    case ancestor_chain(parent, task_id) do
      {:ok, _chain} -> {:ok, chset}
      {:cycle, chain} -> {:error, :dependency_cycle, %{cycle: chain}}
    end
  end

  # Walks from the proposed parent up to the root looking for `task_id`.
  # Finding it means the task is already an ancestor of its own new parent, so
  # attaching would close a loop and orphan the subtree from every root.
  defp ancestor_chain(%Task{} = parent, task_id), do: climb(parent, [], task_id, @max_depth)

  defp climb(%Task{id: id}, chain, _task_id, 0), do: {:cycle, Enum.reverse([id | chain])}

  defp climb(%Task{id: id}, chain, task_id, _depth) when id == task_id do
    {:cycle, Enum.reverse([id | chain])}
  end

  defp climb(%Task{id: id, parent_id: nil}, chain, _task_id, _depth) do
    {:ok, Enum.reverse([id | chain])}
  end

  defp climb(%Task{id: id, parent_id: parent_id}, chain, task_id, depth) do
    case Repo.get(Task, parent_id) do
      nil -> {:ok, Enum.reverse([id | chain])}
      %Task{} = ancestor -> climb(ancestor, [id | chain], task_id, depth - 1)
    end
  end

  # ---------------------------------------------------------------- refusals

  # Reading the row back only on the losing path: the winner already has its
  # record, and only a refusal owes the caller an explanation of which refusal
  # it was.
  defp claim_refusal(task_id) do
    case Repo.get(Task, task_id) do
      nil ->
        {:error, :not_found}

      %Task{assignee_id: assignee_id} = task when not is_nil(assignee_id) ->
        {:error, :task_already_claimed, %{assignee_id: assignee_id, status: task.status}}

      %Task{} = task ->
        {:error, :task_state_conflict, %{status: task.status, expected: Task.live_statuses()}}
    end
  end

  defp require_work(%Task{kind: :summary}) do
    {:error, :task_state_conflict,
     %{kind: :summary, reason: "a summary node holds no work of its own"}}
  end

  defp require_work(%Task{}), do: :ok

  defp allowed_transition(%Task{status: status}, event) do
    case Task.next_status(status, event) do
      {:ok, next} -> {:ok, next}
      :error -> {:error, :task_state_conflict, %{status: status, event: event}}
    end
  end

  defp require_assignee(%Task{status: status, assignee_id: nil}, :start) do
    {:error, :task_state_conflict, %{status: status, reason: "task has no assignee"}}
  end

  defp require_assignee(%Task{}, _event), do: :ok

  defp validate_assignee(actor_id) do
    with {:ok, actor_id} <- cast_actor_id(actor_id),
         true <- Repo.exists?(where(Actor, [actor], actor.id == ^actor_id)) do
      {:ok, actor_id}
    else
      false -> {:error, :validation_error, %{"actor_id" => ["does not exist"]}}
      :error -> {:error, :validation_error, %{"actor_id" => ["is invalid"]}}
    end
  end

  defp cast_actor_id(actor_id) when is_binary(actor_id), do: UUIDv7.cast(actor_id)
  defp cast_actor_id(_actor_id), do: :error
end
