defmodule RintoPMO.Tasks do
  @moduledoc "Executable tasks: assignment, state transitions, estimates, dependencies and scheduling."

  use RintoPMO, :context

  alias Ecto.Changeset
  alias RintoPMO.Actors.Actor
  alias RintoPMO.AIRoles
  alias RintoPMO.Documents.Document
  alias RintoPMO.Links
  alias RintoPMO.Projects.Project
  alias RintoPMO.Projects.ProjectRepo
  alias RintoPMO.References
  alias RintoPMO.References.Guard
  alias RintoPMO.References.Reference
  alias RintoPMO.Requirements.Requirement
  alias RintoPMO.Schedule
  alias RintoPMO.Tasks.Behaviour
  alias RintoPMO.Tasks.Breakdown
  alias RintoPMO.Tasks.Dependency
  alias RintoPMO.Tasks.DependencyGraph
  alias RintoPMO.Tasks.DocumentSync
  alias RintoPMO.Tasks.EstimationWorker
  alias RintoPMO.Tasks.Notifier
  alias RintoPMO.Tasks.Task
  alias RintoPMO.Utils

  # The two questions a model gets asked about a task. Not a schema and not a
  # column: nothing stores a kind, it only travels -- in a job's args, and out
  # on the socket so a client can tell which of the two buttons stopped
  # spinning.
  @estimation_kinds [:difficulty, :time]

  # The one context this one reads: filing a breakdown consumes a document and
  # asks it which design it came from.
  defp documents, do: Utils.module(:documents)

  @behaviour Behaviour

  @impl true
  def list_tasks(%Project{} = project, filter) when is_map(filter) do
    project.id
    |> project_tasks()
    |> filter_tasks(filter)
    |> sort_tasks(filter)
  end

  @impl true
  def list_tasks(filter) when is_map(filter) do
    all_tasks()
    |> filter_tasks(filter)
    |> sort_tasks(filter)
  end

  @doc """
  Fetches a task by id, raising when it does not exist.

  Not scoped through a project: a task id is enough to name one, and the CLI
  that picked a task out of the pool has the id and not the project slug.
  """
  @impl true
  def get_task!(id), do: Repo.get!(Task.with_priority(), id)

  @doc "Creates an open executable task under a leaf requirement and repository."
  @impl true
  def create_task(%Project{} = project, attrs) do
    with :ok <- Guard.check(description_of(attrs)),
         {:ok, attrs} <- put_estimate(attrs),
         {:ok, attrs} <- put_difficulty(attrs),
         {:ok, attrs} <- put_actual(attrs) do
      chset = Task.creation_changeset(%Task{project_id: project.id}, attrs)
      Repo.transact(&insert_task(&1, chset))
    end
  end

  @doc """
  Updates a task's wording, spec pointer, owner, estimates, schedule or due date.

  Status moves only through `transition_task/3` or `transition_task/4`.
  """
  @impl true
  def update_task(%Task{} = task, attrs) do
    with :ok <- Guard.check(description_of(attrs)),
         {:ok, attrs} <- put_estimate(attrs),
         {:ok, attrs} <- put_difficulty(attrs),
         {:ok, attrs} <- put_actual(attrs),
         chset = Task.changeset(task, attrs),
         :ok <- check_schedule_move(task, chset) do
      Repo.transact(&apply_update(&1, chset))
    end
  end

  @doc """
  Schedules only live backlog tasks in the supplied requirements.

  Locks tasks before selecting candidates so concurrent batch requests cannot
  replace an existing plan. All writes and dependency checks share a transaction:
  edges are checked against the final batch, never a partially moved dependency chain.
  """
  def schedule_unplanned_tasks(requirement_ids, %Date{} = day) do
    Repo.transact(fn ->
      tasks =
        Task.with_priority()
        |> where([task], task.requirement_id in ^requirement_ids)
        |> order_by([task], task.id)
        |> lock([task], fragment("FOR UPDATE OF ?", task))
        |> Repo.all()

      {targets, skipped} = Enum.split_with(tasks, &is_nil(schedule_skip_reason(&1)))

      with {:ok, updated} <- write_schedule_batch(targets, day),
           :ok <- check_schedule_batch(updated) do
        {:ok,
         %{
           tasks: updated,
           skipped: Enum.map(skipped, &%{task_id: &1.id, reason: schedule_skip_reason(&1)})
         }}
      else
        {:error, code, details} -> {:error, {code, details}}
        error -> error
      end
    end)
    |> unwrap_refusal()
  end

  defp schedule_skip_reason(task) do
    cond do
      task.status not in [:open, :in_progress] -> :not_live
      not is_nil(task.planned_start_on) -> :already_scheduled
      true -> nil
    end
  end

  defp write_schedule_batch(tasks, day) do
    Enum.reduce_while(tasks, {:ok, []}, fn task, {:ok, updated} ->
      case task |> Task.changeset(%{planned_start_on: day}) |> Repo.update() do
        {:ok, task} -> {:cont, {:ok, [task | updated]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, updated} -> {:ok, Enum.reverse(updated)}
      error -> error
    end
  end

  defp check_schedule_batch(tasks) do
    Enum.reduce_while(tasks, :ok, fn task, :ok ->
      with :ok <- check_dependency_schedule(task, list_dependencies(task)),
           :ok <- check_dependents_schedule(task, list_dependents(task)) do
        {:cont, :ok}
      else
        error -> {:halt, error}
      end
    end)
  end

  # The transaction exists so the index is written with the task rather than
  # after it -- see `RintoPMO.Links`. It is also where `create_task/2` and
  # `update_task/2` each keep the rest of their one-atomic-act work.
  defp description_of(attrs), do: Map.get(attrs, :description) || Map.get(attrs, "description")

  defp insert_task(repo, chset) do
    with {:ok, task} <- chset |> validate_requirement() |> validate_repo() |> repo.insert() do
      index(repo, task)
      inherited_priority({:ok, task})
    end
  end

  defp apply_update(repo, chset) do
    with {:ok, updated} <- chset |> validate_repo() |> repo.update() do
      index(repo, updated)
      inherited_priority({:ok, updated})
    end
  end

  defp index(repo, %Task{} = task) do
    Links.sync(repo, "task", task.id, task.description)
  end

  @doc "Deletes a task and its links, cascading dependency edges and refreshing the graph."
  @impl true
  def delete_task(%Task{} = task) do
    # The edges go with the row, in the database, by cascade -- which the
    # application never sees, so the cache is told here. Forgetting to would
    # only leave edges behind that refuse a later addition they should have
    # allowed; see `RintoPMO.Tasks.DependencyGraph`.
    with {:ok, deleted} <- unwrap_refusal(Repo.transact(&remove(&1, task))) do
      :ok = DependencyGraph.forget_task(task.id)
      {:ok, deleted}
    end
  end

  defp remove(repo, %Task{} = task) do
    Links.purge(repo, "task", task.id)
    repo.delete(task)
  end

  @doc """
  Assigns a task to an actor, overwriting any current assignee.

  The authoritative half of distribution: a PM reassigning does not have to
  release first, because a handoff is one decision and should not be able to
  half-happen.
  """
  @impl true
  def assign_task(%Task{} = task, actor_id) do
    with {:ok, actor_id} <- validate_assignee(actor_id) do
      task
      |> Task.assignment_changeset(actor_id)
      |> Repo.update()
      |> inherited_priority()
    end
  end

  @doc "Atomically claims an unassigned live task; concurrent losers receive a refusal."
  @impl true
  def claim_task(%Task{} = task, actor_id) do
    with {:ok, actor_id} <- validate_assignee(actor_id) do
      now = DateTime.utc_now()
      live_statuses = Task.live_statuses()

      claimed =
        Task
        |> where([candidate], candidate.id == ^task.id)
        |> where([candidate], is_nil(candidate.assignee_id))
        |> where([candidate], candidate.status in ^live_statuses)
        |> select([candidate], candidate)
        |> Repo.update_all(set: [assignee_id: actor_id, assigned_at: now, updated_at: now])

      case claimed do
        {1, [task]} -> inherited_priority({:ok, task})
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

  `actor_id` is who is letting go, and it has to be the actor holding the task
  -- putting somebody else's work back in the pool is `assign_task/2`, which
  says whose it becomes rather than leaving it to whoever looks next.
  """
  @impl true
  def release_task(%Task{} = task, actor_id) do
    with :ok <- require_owner(task, actor_id) do
      task
      |> Task.assignment_changeset(nil)
      |> Repo.update()
      |> inherited_priority()
    end
  end

  @doc "Moves task state. Starting and completing require the assignee; completion records duration."
  @impl true
  def transition_task(%Task{} = task, event, actor_id) when is_atom(event) do
    transition_task(task, event, actor_id, %{})
  end

  @impl true
  def transition_task(%Task{} = task, :start, actor_id, attrs) when is_map(attrs) do
    # Match document sync's lock order: requirement before task. A manual status
    # change cannot be overwritten by an automatic start based on stale data.
    Repo.transaction(fn ->
      Repo.one!(
        from r in RintoPMO.Requirements.Requirement,
          where: r.id == ^task.requirement_id,
          lock: "FOR UPDATE"
      )

      current = Repo.one!(from t in Task, where: t.id == ^task.id, lock: "FOR UPDATE")

      case do_transition_task(current, :start, actor_id, attrs) do
        {:ok, started} ->
          from(r in RintoPMO.Requirements.Requirement,
            where:
              r.id == ^started.requirement_id and r.status in [:draft, :analyzed] and
                is_nil(r.archived_at)
          )
          |> Repo.update_all(set: [status: :active, updated_at: DateTime.utc_now()])

          started

        error ->
          Repo.rollback(error)
      end
    end)
    |> case do
      {:ok, started} -> {:ok, started}
      {:error, error} -> error
    end
  end

  def transition_task(%Task{} = task, event, actor_id, attrs) when is_map(attrs),
    do: do_transition_task(task, event, actor_id, attrs)

  defp do_transition_task(task, event, actor_id, attrs) do
    with {:ok, _next} <- allowed_transition(task, event),
         :ok <- require_owner(task, event, actor_id),
         {:ok, attrs} <- complete_attrs(event, attrs) do
      task
      |> Task.transition_changeset(event, attrs)
      |> Repo.update()
      |> inherited_priority()
    end
  end

  @impl true
  def sync_document(document, attrs), do: DocumentSync.sync(document, attrs)

  @doc "Files an adopted task document as executable tasks and marks it applied in one transaction."
  @impl true
  def file_breakdown(%Document{} = breakdown) do
    with {:ok, blocks} <- breakdown_blocks(breakdown),
         {:ok, chunks} <- Breakdown.parse(blocks) do
      chunks
      |> file(breakdown, spec_of(blocks))
      |> unwrap_refusal()
    end
  end

  # The work and the document's last state move together or not at all.
  defp file(chunks, %Document{} = breakdown, spec) do
    Repo.transact(fn repo ->
      current = repo.one!(from d in Document, where: d.id == ^breakdown.id, lock: "FOR UPDATE")

      with :ok <- validate_legacy_filing(current),
           {:ok, filed} <- insert_chunks(chunks, current, spec, repo),
           {:ok, _applied} <- documents().apply_document(breakdown) do
        {:ok, filed}
      end
    end)
  end

  defp validate_legacy_filing(%Document{status: :formal} = document) do
    if Repo.exists?(
         from entry in RintoPMO.Tasks.DocumentEntry, where: entry.document_id == ^document.id
       ),
       do:
         {:error,
          {:task_sync_conflict,
           %{document_id: document.id, reason: "use task sync for this document"}}},
       else: :ok
  end

  defp validate_legacy_filing(document),
    do: {:error, {:document_not_formal, %{status: document.status}}}

  # Refused here as well as by `apply_document/1` inside the transaction. The
  # one inside is the guarantee; this one is so that a person who clicked the
  # wrong button is told which document and what state, rather than getting a
  # changeset error about a field they never sent.
  defp breakdown_blocks(%Document{status: :formal} = breakdown) do
    blocks =
      breakdown.id
      |> documents().get_document!()
      |> Map.fetch!(:latest_revision)
      |> Map.fetch!(:blocks)

    {:ok, blocks}
  end

  defp breakdown_blocks(%Document{status: status}) do
    {:error, :document_not_formal, %{status: status}}
  end

  # The first document the preamble points at. First rather than only: a
  # preamble is prose and may cite more than one thing, and the line the prompt
  # writes puts the source at the front of it.
  #
  # A body that will not parse, a link to something that is not a document, an
  # id that no longer resolves -- all of them come back as no spec rather than
  # as a refusal. Filing work is the point of the call, and a broken provenance
  # line is not a reason to withhold the tasks somebody adopted.
  defp spec_of(blocks) do
    blocks
    |> Breakdown.preamble()
    |> Enum.flat_map(&references_in/1)
    |> Enum.find_value(&fetch_document/1)
  end

  defp references_in(%{content: content}) when is_binary(content) do
    case References.extract(content) do
      {:ok, found} -> Enum.map(found, & &1.reference)
      {:error, _unparseable} -> []
    end
  end

  defp references_in(_block), do: []

  defp fetch_document(%Reference{type: "document", key: id}) do
    documents().get_document!(id)
  rescue
    Ecto.NoResultsError -> nil
    Ecto.Query.CastError -> nil
  end

  defp fetch_document(_other_type), do: nil

  defp insert_chunks(chunks, %Document{} = breakdown, spec, repo) do
    chunks
    |> Enum.reduce_while({:ok, []}, fn chunk, {:ok, filed} ->
      case insert_chunk(chunk, breakdown, spec, repo) do
        {:ok, created} -> {:cont, {:ok, Enum.reverse(created) ++ filed}}
        {:error, chset} -> {:halt, {:error, {:validation_error, chunk_errors(chunk, chset)}}}
        {:error, code, details} -> {:halt, {:error, {code, details}}}
      end
    end)
    |> case do
      {:ok, filed} -> {:ok, Enum.reverse(filed)}
      error -> error
    end
  end

  defp insert_chunk(chunk, breakdown, spec, repo) do
    nodes = if chunk.tasks == [], do: [chunk], else: chunk.tasks

    Enum.reduce_while(nodes, {:ok, []}, fn node, {:ok, created} ->
      case insert_node(node, breakdown, spec, repo) do
        {:ok, task} -> {:cont, {:ok, created ++ [task]}}
        error -> {:halt, error}
      end
    end)
  end

  defp insert_node(node, %Document{} = breakdown, spec, repo) do
    %Task{
      project_id: breakdown.project_id,
      requirement_id: breakdown.requirement_id,
      repo_id: sole_repo_id(breakdown.project_id)
    }
    |> Task.creation_changeset(%{
      title: node.title,
      description: node.description,
      document_id: spec && spec.id
    })
    |> validate_requirement()
    |> validate_repo()
    |> repo.insert()
    |> inherited_priority()
  end

  # Which heading failed, said the way the document says it. An index into a
  # list nobody wrote as a list would send somebody counting blocks.
  defp chunk_errors(chunk, chset) do
    %{"chunk" => chunk.title, "errors" => Changeset.traverse_errors(chset, &elem(&1, 0))}
  end

  @doc "Counts tasks by status and assignee, with estimates and actual durations."
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
        unestimated_tasks: filter(count(task.id), is_nil(task.estimate_optimistic)),
        actual: sum(task.actual_minutes),
        unmeasured_tasks: filter(count(task.id), is_nil(task.actual_minutes))
      })
      |> Repo.all()

    %{
      total: Enum.sum_by(rows, & &1.count),
      unassigned: rows |> Enum.filter(&is_nil(&1.assignee_id)) |> Enum.sum_by(& &1.count),
      overdue: count_overdue(project),
      by_status: by_status(rows),
      by_assignee: by_assignee(rows),
      estimate: estimate_stats(rows),
      actual: actual_stats(rows)
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

  defp actual_stats(rows) do
    %{
      total: rows |> Enum.map(& &1.actual) |> sum_present(),
      unmeasured_tasks: Enum.sum_by(rows, & &1.unmeasured_tasks)
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
  end

  @doc "Queues an estimate for this task when its requested value is missing."
  @impl true
  def request_estimation(%Task{} = task, kind) when kind in @estimation_kinds do
    with :ok <- something_to_estimate(task, kind),
         {:ok, _role} <- estimation_ai() do
      enqueue_estimation(task, kind)
    end
  end

  @doc """
  Runs one estimation: the model call, the writes, and the word to whoever is
  watching.

  Called by the worker and not by a request. There is no row to move through
  states -- what happened is the numbers on the tasks, and the only thing that
  needs saying is that it is over. So the last thing this does either way is
  broadcast the outcome on `RintoPMO.Tasks.Notifier`.

  Answers `:ok`, or `{:cancel, reason}` when the model call failed. `:cancel`
  and not `:error`: this is over either way, and asking the same question
  nineteen more times is not a retry policy, it is nineteen more model calls.
  The reason lands in the job's own `errors`, which is where somebody
  debugging a provider looks, and it goes out on the socket in the same
  breath, which is where the person who clicked sees it.
  """
  @impl true
  def run_estimation(job_id, task_id, kind) when kind in @estimation_kinds do
    case Repo.get(Task, task_id) do
      # The task was deleted while the job waited. Nothing to run and nobody
      # to tell -- the topic it would be announced on is a topic for a task
      # that is not there.
      nil ->
        :ok

      task ->
        case unfilled_work(task, kind) do
          # Somebody filled everything in while the job waited. That is the
          # result they wanted, so it is a success and not a complaint.
          [] -> succeed(job_id, task_id, kind)
          targets -> estimate_and_apply(job_id, task, kind, targets)
        end
    end
  end

  defp something_to_estimate(task, kind) do
    if unfilled_work(task, kind) == [],
      do: {:error, :nothing_to_estimate, %{kind: kind, reason: "the task already has a value"}},
      else: :ok
  end

  defp unfilled_work(task, :difficulty), do: if(is_nil(task.difficulty), do: [task], else: [])
  defp unfilled_work(task, :time), do: if(is_nil(task.estimate_optimistic), do: [task], else: [])

  # Refused rather than fallen back on. Estimation belongs to no conversation,
  # so unlike naming there is no other configuration standing there to inherit
  # -- and picking a model off the catalogue would be this module inventing an
  # answer nobody gave it.
  defp estimation_ai do
    case AIRoles.get_role("task_estimation") do
      nil -> {:error, :no_estimation_ai, %{}}
      role -> {:ok, role}
    end
  end

  # Deduplicated over `:incomplete` only, and over the question rather than
  # the asking of it: a double-click while one is in flight gets the job that
  # is already queued, and a deliberate second ask, after the first is over,
  # gets a job of its own.
  defp enqueue_estimation(%Task{} = task, kind) do
    %{task_id: task.id, kind: kind}
    |> EstimationWorker.new()
    |> Oban.insert()
  end

  defp estimate_and_apply(job_id, %Task{} = task, kind, targets) do
    with {:ok, role} <- estimation_ai(),
         {:ok, items} <- call_estimator(kind, task, targets, role) do
      case apply_estimation(kind, targets, items) do
        0 -> fail(job_id, task.id, kind, "the model did not estimate any of the tasks")
        _count -> succeed(job_id, task.id, kind)
      end
    else
      {:error, :no_estimation_ai, _details} ->
        fail(job_id, task.id, kind, "the task estimation AI is not configured")

      {:error, reason} ->
        fail(job_id, task.id, kind, failure_reason(reason))
    end
  end

  defp call_estimator(kind, %Task{} = task, targets, role) do
    opts = [
      provider: role.provider,
      model: role.model,
      thinking: role.thinking_level,
      system_prompt: role.system_prompt
    ]

    case kind do
      :difficulty ->
        task_estimator().estimate_difficulty(%{tasks: Enum.map(targets, &task_payload/1)}, opts)

      :time ->
        input = %{
          tasks: Enum.map(targets, &task_payload_with_difficulty/1),
          history: history(task.project_id)
        }

        task_estimator().estimate_time(input, opts)
    end
  end

  defp task_payload(%Task{} = task) do
    %{id: to_string(task.id), title: task.title, description: task.description}
  end

  defp task_payload_with_difficulty(%Task{} = task) do
    Map.put(task_payload(task), :difficulty, task.difficulty)
  end

  defp history(project_id) do
    Task
    |> where([task], task.project_id == ^project_id)
    |> where([task], task.status == :done)
    |> where([task], not is_nil(task.actual_minutes))
    |> order_by([task], desc: task.completed_at)
    |> limit(50)
    |> Repo.all()
    |> Enum.map(&history_item/1)
  end

  defp history_item(%Task{} = task) do
    %{
      title: task.title,
      difficulty: task.difficulty,
      estimate: history_estimate(task),
      actual_minutes: task.actual_minutes
    }
  end

  defp history_estimate(%Task{estimate_optimistic: nil}), do: nil

  defp history_estimate(%Task{} = task) do
    %{
      optimistic: task.estimate_optimistic,
      likely: task.estimate_likely,
      pessimistic: task.estimate_pessimistic,
      expected: Task.expected(task)
    }
  end

  defp apply_estimation(:difficulty, targets, items) do
    allowed = Map.new(targets, &{to_string(&1.id), &1})

    Enum.reduce(items, 0, fn item, count ->
      with id when is_binary(id) <- Map.get(item, "id"),
           %Task{} = task <- Map.get(allowed, id),
           {:ok, _updated} <- write_difficulty(task, Map.get(item, "difficulty")) do
        count + 1
      else
        _skipped -> count
      end
    end)
  end

  defp apply_estimation(:time, targets, items) do
    allowed = Map.new(targets, &{to_string(&1.id), &1})

    Enum.reduce(items, 0, fn item, count ->
      with id when is_binary(id) <- Map.get(item, "id"),
           %Task{} = task <- Map.get(allowed, id),
           {:ok, _updated} <- write_estimate(task, item) do
        count + 1
      else
        _skipped -> count
      end
    end)
  end

  defp write_difficulty(%Task{difficulty: difficulty}, _value) when not is_nil(difficulty) do
    :already_set
  end

  defp write_difficulty(%Task{} = task, value) do
    case put_difficulty(%{"difficulty" => value}) do
      {:ok, attrs} -> task |> Task.changeset(attrs) |> Repo.update()
      _invalid -> :invalid
    end
  end

  defp write_estimate(%Task{estimate_optimistic: minutes}, _item) when not is_nil(minutes) do
    :already_set
  end

  defp write_estimate(%Task{} = task, item) do
    estimate = %{
      "optimistic" => Map.get(item, "optimistic"),
      "likely" => Map.get(item, "likely"),
      "pessimistic" => Map.get(item, "pessimistic")
    }

    case put_estimate(%{"estimate" => estimate}) do
      {:ok, attrs} -> write_estimate_if_unchanged(task, attrs)
      _invalid -> :invalid
    end
  end

  @doc "Validates a complete AI batch and writes it atomically without replacing changed tasks."
  def apply_time_estimates(targets, items) when is_list(items) do
    expected = Enum.sort(Enum.map(targets, & &1.id))
    actual = Enum.map(items, fn item -> if is_map(item), do: Map.get(item, "id") end)

    if Enum.sort(actual) == expected do
      by_id = Map.new(items, &{&1["id"], &1})

      Repo.transact(fn -> write_estimation_batch(targets, by_id) end)
      |> case do
        {:ok, :ok} -> :ok
        {:error, reason} -> {:error, reason}
      end
    else
      {:error, "the model must estimate every requested task exactly once, with no extra IDs"}
    end
  end

  def apply_time_estimates(_targets, _items),
    do: {:error, "the model did not return an estimate list"}

  defp write_estimation_batch(targets, by_id) do
    Enum.reduce_while(targets, {:ok, :ok}, fn task, _acc ->
      case write_estimate(task, Map.fetch!(by_id, task.id)) do
        {:ok, _updated} ->
          {:cont, {:ok, :ok}}

        :invalid ->
          {:halt,
           {:error,
            "invalid estimate for #{task.id}; use non-negative whole minutes with optimistic <= likely <= pessimistic"}}

        _changed ->
          {:halt, {:error, "task #{task.id} changed during estimation; run it again"}}
      end
    end)
  end

  defp write_estimate_if_unchanged(task, attrs) do
    Repo.transact(fn ->
      current =
        Repo.one(from candidate in Task, where: candidate.id == ^task.id, lock: "FOR UPDATE")

      if same_estimation_target?(current, task) do
        current |> Task.changeset(attrs) |> Repo.update()
      else
        {:error, :changed}
      end
    end)
  end

  defp same_estimation_target?(nil, _task), do: false

  defp same_estimation_target?(current, task) do
    fields = [
      :updated_at,
      :title,
      :description,
      :difficulty,
      :status,
      :requirement_id,
      :estimate_optimistic,
      :estimate_likely,
      :estimate_pessimistic
    ]

    Map.take(current, fields) == Map.take(task, fields) and is_nil(current.estimate_optimistic)
  end

  defp succeed(job_id, task_id, kind) do
    :ok = Notifier.broadcast_estimation(job_id, task_id, kind, :succeeded, nil)
    :ok
  end

  # Told twice, on purpose, and to two different audiences. The broadcast is
  # for the person watching, and carries the sentence on its own; it is gone
  # the moment it is delivered. The `:cancel` leaves the same words in the
  # job's `errors`, wrapped by Oban in an `Oban.PerformError` and inspected --
  # readable enough for somebody debugging a provider, which is the only
  # reader that copy has.
  defp fail(job_id, task_id, kind, reason) when is_binary(reason) do
    :ok = Notifier.broadcast_estimation(job_id, task_id, kind, :failed, reason)
    {:cancel, reason}
  end

  defp failure_reason({:pi_exit, code, ""}), do: "the model call exited #{code}, saying nothing"
  defp failure_reason({:pi_exit, _code, complaint}), do: complaint
  defp failure_reason({:provider_refused, complaint}), do: complaint
  defp failure_reason(:stalled), do: "the model stopped responding"
  defp failure_reason(:empty_output), do: "the model answered with nothing"
  defp failure_reason(:pi_not_found), do: "the agent runtime is not installed on the server"
  defp failure_reason(:invalid_output), do: "the model did not return a JSON array of estimates"
  defp failure_reason(other), do: inspect(other)

  defp task_estimator, do: Utils.module(:task_estimator)

  defp project_tasks(project_id) do
    Task |> where([task], task.project_id == ^project_id) |> read_tasks()
  end

  defp all_tasks, do: read_tasks(Task)

  defp read_tasks(query) do
    query |> order_by([task], asc: task.id) |> Task.with_priority() |> Repo.all()
  end

  # ---------------------------------------------------------------- filtering

  defp filter_tasks(tasks, filter) do
    live_statuses = Task.live_statuses()
    today = Date.utc_today()

    Enum.filter(tasks, fn task ->
      Enum.all?(filter, fn
        {:status, status} -> task.status == status
        {:assignee_id, assignee_id} -> task.assignee_id == assignee_id
        {:document_id, document_id} -> task.document_id == document_id
        {:repo_id, repo_id} -> task.repo_id == repo_id
        {:live, live} -> task.status in live_statuses == live
        {:overdue, overdue} -> overdue?(task, live_statuses, today) == overdue
        {:priority, priority} -> task.priority == priority
        {:scheduled, scheduled} -> not is_nil(task.planned_start_on) == scheduled
        {_other, _value} -> true
      end)
    end)
  end

  # `:sort` travels in the filter map because it comes off the same query
  # string, but it selects nothing -- hence its own pass rather than a clause
  # in `filter_tasks/2` that would have to answer `true` for every task.
  #
  # `:plan` is `RintoPMO.Schedule.order/1` itself rather than a copy of it.
  # "Which of these should be done first" has one answer in this system, and a
  # list that sorted by priority alone would disagree with the board over two
  # tasks of equal priority selected for different days.
  defp sort_tasks(tasks, filter) do
    case Map.get(filter, :sort, :oldest) do
      :plan -> Schedule.order(tasks)
      _oldest -> tasks
    end
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
  defp put_estimate(attrs) do
    attrs = attrs |> stringify_keys() |> Map.drop(@estimate_columns)

    case Map.fetch(attrs, "estimate") do
      :error -> {:ok, attrs}
      {:ok, nil} -> {:ok, Map.merge(attrs, clear_estimate())}
      {:ok, estimate} -> cast_estimate(attrs, estimate)
    end
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

  @spec add_dependency(Task.t(), UUIDv7.t()) ::
          {:ok, Dependency.t()} | {:error, Changeset.t()} | Behaviour.refusal()
  @impl Behaviour
  def add_dependency(%Task{} = task, depends_on_id) do
    with {:ok, prerequisite} <- fetch_dependable(task, depends_on_id),
         :ok <- check_dependency_cycle(task, prerequisite),
         :ok <- check_dependency_schedule(task, [prerequisite]) do
      # The cache is written immediately after the row, in this process. A
      # missing edge is the one kind of staleness that could let a real cycle
      # through, so it is the one kind that is not allowed to depend on
      # anything asynchronous.
      with {:ok, edge} <-
             %{task_id: task.id, depends_on_id: prerequisite.id}
             |> Dependency.changeset()
             |> Repo.insert() do
        :ok = DependencyGraph.put(task.id, prerequisite.id)
        {:ok, edge}
      end
    end
  end

  @doc """
  Removes an edge. Absent is the same as removed.
  """
  @spec remove_dependency(Task.t(), UUIDv7.t()) :: :ok
  @impl Behaviour
  def remove_dependency(%Task{} = task, depends_on_id) do
    Dependency
    |> where([edge], edge.task_id == ^task.id and edge.depends_on_id == ^depends_on_id)
    |> Repo.delete_all()

    DependencyGraph.drop(task.id, depends_on_id)
  end

  @doc """
  What `task` is waiting for.
  """
  @spec list_dependencies(Task.t()) :: [Task.t()]
  @impl Behaviour
  def list_dependencies(%Task{} = task) do
    Task
    |> join(:inner, [prerequisite], edge in Dependency, on: edge.depends_on_id == prerequisite.id)
    |> where([_prerequisite, edge], edge.task_id == ^task.id)
    |> order_by([prerequisite], asc: prerequisite.inserted_at)
    |> Task.with_priority()
    |> Repo.all()
  end

  @doc """
  Every edge at once, for drawing rather than for asking about one task.

  A chart that wanted arrows had to call `list_dependencies/1` per task, which
  is a request per bar. The edges are two ids each; there is no reason for the
  round trips.

  Scoped to a project, this answers every edge with **either** end in it, not
  only the ones with both. A dependency reaching outside the project is a real
  constraint on the work being drawn, and leaving it out would produce a chart
  that looks unconstrained while the task waits on something. The client can
  see which id it does not have, and say so.

  Ordered by the edge's own id, so a repeated call draws the same picture.
  """
  @spec list_edges(UUIDv7.t() | nil) :: [%{task_id: UUIDv7.t(), depends_on_id: UUIDv7.t()}]
  @impl Behaviour
  def list_edges(project_id \\ nil) do
    Dependency
    |> join(:inner, [edge], waiting in Task, on: waiting.id == edge.task_id)
    |> join(:inner, [edge], prerequisite in Task, on: prerequisite.id == edge.depends_on_id)
    |> then(fn query ->
      if project_id do
        where(
          query,
          [_edge, waiting, prerequisite],
          waiting.project_id == ^project_id or prerequisite.project_id == ^project_id
        )
      else
        query
      end
    end)
    |> order_by([edge], asc: edge.id)
    |> select([edge], %{task_id: edge.task_id, depends_on_id: edge.depends_on_id})
    |> Repo.all()
  end

  @doc """
  What is waiting for `task`.
  """
  @spec list_dependents(Task.t()) :: [Task.t()]
  @impl Behaviour
  def list_dependents(%Task{} = task) do
    Task
    |> join(:inner, [waiting], edge in Dependency, on: edge.task_id == waiting.id)
    |> where([_waiting, edge], edge.depends_on_id == ^task.id)
    |> order_by([waiting], asc: waiting.inserted_at)
    |> Task.with_priority()
    |> Repo.all()
  end

  defp fetch_dependable(%Task{}, depends_on_id) do
    case Repo.get(Task, depends_on_id) do
      nil -> {:error, :task_not_found, %{depends_on_id: depends_on_id}}
      %Task{} = prerequisite -> {:ok, prerequisite}
    end
  end

  # "A depends on B" closes a loop exactly when B already depends on A, through
  # any chain. So there is no graph to build and nothing to test for acyclicity:
  # one reachability walk over `RintoPMO.Tasks.DependencyGraph`, in memory, no
  # query. The walk returns the chain, so the refusal still names the loop.
  #
  # A task depending on itself is the same question with a chain of one, and is
  # answered here rather than by the check constraint underneath, which is the
  # backstop.
  defp check_dependency_cycle(%Task{id: id}, %Task{id: id}),
    do: {:error, :dependency_cycle, %{cycle: [id]}}

  defp check_dependency_cycle(%Task{} = task, %Task{} = prerequisite) do
    case DependencyGraph.path(task.id, prerequisite.id) do
      nil -> :ok
      chain -> {:error, :dependency_cycle, %{cycle: chain}}
    end
  end

  # The rule the database cannot hold, because it spans rows: a prerequisite
  # that is still live has to be selected into a week no later than the work
  # waiting on it.
  #
  # "Still live" is the whole of it. A `:done` prerequisite constrains nothing,
  # and neither does a `:cancelled` one -- freezing everything downstream of a
  # dropped task would leave no way out except deleting an edge that is still a
  # true statement about the work.
  #
  # Nothing is checked when the waiting task is unscheduled: a task in the
  # backlog claims to happen at no particular time, so there is nothing for a
  # prerequisite to be later than.
  # The same rule, from the other two directions. Moving a task is moving one
  # end of every edge it sits on, so both ends get checked: the work it waits
  # for must not end up later than it, and the work waiting on it must not end
  # up earlier.
  #
  # Only when the day actually changes. Editing a title must not be able to
  # fail because of a conflict somebody else created.
  defp check_schedule_move(%Task{} = task, chset) do
    case Changeset.fetch_change(chset, :planned_start_on) do
      :error ->
        :ok

      {:ok, day} ->
        moved = %{task | planned_start_on: day}

        with :ok <- check_dependency_schedule(moved, list_dependencies(task)) do
          check_dependents_schedule(moved, list_dependents(task))
        end
    end
  end

  defp check_dependents_schedule(%Task{} = moved, dependents) do
    Enum.reduce_while(dependents, :ok, fn dependent, :ok ->
      case check_dependency_schedule(dependent, [moved]) do
        :ok -> {:cont, :ok}
        refusal -> {:halt, refusal}
      end
    end)
  end

  defp check_dependency_schedule(%Task{planned_start_on: nil}, _prerequisites), do: :ok

  defp check_dependency_schedule(%Task{} = task, prerequisites) do
    live = Task.live_statuses()

    conflicting =
      Enum.find(prerequisites, fn prerequisite ->
        prerequisite.status in live and
          (is_nil(prerequisite.planned_start_on) or
             Date.after?(prerequisite.planned_start_on, task.planned_start_on))
      end)

    case conflicting do
      nil ->
        :ok

      %Task{} = prerequisite ->
        {:error, :dependency_out_of_order,
         %{
           task_id: task.id,
           planned_start_on: task.planned_start_on,
           depends_on_id: prerequisite.id,
           depends_on_planned_start_on: prerequisite.planned_start_on
         }}
    end
  end

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {to_string(key), value} end)
  end

  @difficulties [1, 2, 3, 5, 8, 13, 21]

  defp put_difficulty(attrs) do
    attrs = stringify_keys(attrs)

    case Map.fetch(attrs, "difficulty") do
      :error ->
        {:ok, attrs}

      {:ok, nil} ->
        {:ok, attrs}

      {:ok, value} when value in @difficulties ->
        {:ok, attrs}

      {:ok, _invalid} ->
        {:error, :invalid_difficulty,
         %{
           field: "difficulty",
           reason: "must be a Fibonacci story point (1, 2, 3, 5, 8, 13, 21)"
         }}
    end
  end

  defp put_actual(attrs) do
    attrs = stringify_keys(attrs)

    case Map.fetch(attrs, "actual_minutes") do
      :error ->
        {:ok, attrs}

      {:ok, nil} ->
        {:ok, attrs}

      {:ok, value} when is_integer(value) and value >= 0 ->
        {:ok, attrs}

      {:ok, _invalid} ->
        {:error, :invalid_actual,
         %{field: "actual_minutes", reason: "must be a non-negative whole number of minutes"}}
    end
  end

  defp complete_attrs(:complete, attrs) do
    attrs = stringify_keys(attrs)

    case Map.fetch(attrs, "actual_minutes") do
      :error ->
        {:ok, %{}}

      {:ok, nil} ->
        {:ok, %{}}

      {:ok, value} when is_integer(value) and value >= 0 ->
        {:ok, %{"actual_minutes" => value}}

      {:ok, _invalid} ->
        {:error, :invalid_actual,
         %{field: "actual_minutes", reason: "must be a non-negative whole number of minutes"}}
    end
  end

  defp complete_attrs(_event, _attrs), do: {:ok, %{}}

  defp sole_repo_id(project_id) do
    case Repo.all(
           from repo in ProjectRepo,
             where: repo.project_id == ^project_id,
             select: repo.id,
             limit: 2
         ) do
      [id] -> id
      _other -> nil
    end
  end

  defp validate_repo(%Changeset{valid?: false} = chset), do: chset

  defp validate_repo(chset) do
    id = Changeset.get_field(chset, :repo_id)
    project_id = Changeset.get_field(chset, :project_id)

    if Repo.exists?(
         from repo in ProjectRepo, where: repo.id == ^id and repo.project_id == ^project_id
       ) do
      chset
    else
      Changeset.add_error(chset, :repo_id, "must be a repository in this project")
    end
  end

  # Called inside the task-creation transaction. Requirement child creation
  # locks the same row, so task ownership and leaf status cannot race.
  defp validate_requirement(%Changeset{valid?: false} = chset), do: chset

  defp validate_requirement(chset) do
    id = Changeset.get_field(chset, :requirement_id)
    project_id = Changeset.get_field(chset, :project_id)

    requirement =
      Repo.one(from requirement in Requirement, where: requirement.id == ^id, lock: "FOR UPDATE")

    case requirement do
      %Requirement{project_id: ^project_id, archived_at: nil, status: status}
      when status in [:draft, :analyzed, :active] ->
        if Repo.exists?(
             from child in Requirement,
               where: child.parent_id == ^id and is_nil(child.archived_at)
           ) do
          Changeset.add_error(chset, :requirement_id, "must be a leaf requirement")
        else
          chset
        end

      _other ->
        Changeset.add_error(chset, :requirement_id, "must be an open requirement in this project")
    end
  end

  defp inherited_priority({:ok, %Task{} = task}) do
    priority =
      Repo.one!(
        from requirement in Requirement,
          where: requirement.id == ^task.requirement_id,
          select: requirement.priority
      )

    {:ok, %{task | priority: priority}}
  end

  defp inherited_priority(result), do: result

  defp unwrap_refusal({:error, {code, details}}), do: {:error, code, details}
  defp unwrap_refusal(result), do: result

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

  defp allowed_transition(%Task{status: status}, event) do
    case Task.next_status(status, event) do
      {:ok, next} -> {:ok, next}
      :error -> {:error, :task_state_conflict, %{status: status, event: event}}
    end
  end

  # The events that are the assignee's to make. See `transition_task/4` for why
  # `:cancel` and `:reopen` are not among them.
  @owned_events [:start, :complete]

  defp require_owner(%Task{} = task, event, actor_id) when event in @owned_events do
    require_owner(task, actor_id)
  end

  defp require_owner(%Task{}, _event, _actor_id), do: :ok

  # Two refusals rather than one, because they have two different answers.
  # Nobody holds it: claim it and carry on. Somebody else holds it: this was the
  # wrong task, and no amount of re-reading state will change that -- which is
  # also why the second is a 403 and the first a 409.
  defp require_owner(%Task{status: status, assignee_id: nil}, _actor_id) do
    {:error, :task_state_conflict, %{status: status, reason: "task has no assignee"}}
  end

  defp require_owner(%Task{assignee_id: assignee_id}, actor_id)
       when assignee_id == actor_id,
       do: :ok

  defp require_owner(%Task{assignee_id: assignee_id}, _actor_id) do
    {:error, :task_not_yours, %{assignee_id: assignee_id}}
  end

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
