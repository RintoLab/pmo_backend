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
  alias RintoPMO.Documents.Document
  alias RintoPMO.Links
  alias RintoPMO.Projects.Project
  alias RintoPMO.Settings
  alias RintoPMO.Tasks.Breakdown
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

  # A parent chain deeper than this is a corrupt tree, not a breakdown. The
  # bound exists so a cycle written by some future path fails loudly here
  # instead of spinning.
  @max_depth 64

  defmodule Behaviour do
    @moduledoc false

    alias RintoPMO.Projects.Project
    alias RintoPMO.Tasks.Task

    @typedoc """
    Which of the two questions a model is being asked about a task.
    """
    @type estimation_kind :: :difficulty | :time

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
            },
            actual: %{
              total: non_neg_integer() | nil,
              unmeasured_tasks: non_neg_integer()
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
    @callback transition_task(Task.t(), Task.event(), map()) ::
                {:ok, Task.t()} | {:error, Ecto.Changeset.t()} | refusal()

    @callback request_estimation(Task.t(), estimation_kind()) ::
                {:ok, Oban.Job.t()} | refusal()
    @callback run_estimation(integer(), UUIDv7.t(), estimation_kind()) ::
                :ok | {:cancel, String.t()}

    @callback split_task(Task.t(), [map()]) ::
                {:ok, Task.t()} | {:error, Ecto.Changeset.t()} | refusal()

    @callback file_breakdown(RintoPMO.Documents.Document.t()) ::
                {:ok, [Task.t()]} | {:error, Ecto.Changeset.t()} | refusal()

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
    kind = kind_of(attrs)

    with {:ok, attrs} <- put_estimate(attrs, kind),
         {:ok, attrs} <- put_difficulty(attrs, kind),
         {:ok, attrs} <- put_actual(attrs, kind),
         chset = Task.creation_changeset(%Task{project_id: project.id}, attrs),
         {:ok, chset} <- validate_parent(chset, project.id, nil) do
      Repo.transact(&insert_task(&1, chset))
    end
  end

  @doc """
  Updates a task's wording, spec pointer, place in the tree, owner, or due date.

  Neither `status` nor `kind` is accepted here. Status moves only through
  `transition_task/2`; `kind` never moves at all.
  """
  @impl true
  def update_task(%Task{} = task, attrs) do
    with {:ok, attrs} <- put_estimate(attrs, task.kind),
         {:ok, attrs} <- put_difficulty(attrs, task.kind),
         {:ok, attrs} <- put_actual(attrs, task.kind),
         chset = Task.changeset(task, attrs),
         {:ok, chset} <- validate_parent(chset, task.project_id, task.id) do
      Repo.transact(&apply_move(&1, chset, task.parent_id))
    end
  end

  # The transaction exists so the index is written with the task rather than
  # after it -- see `RintoPMO.Links`. It is also where `create_task/2` and
  # `update_task/2` each keep the rest of their one-atomic-act work.
  defp insert_task(repo, chset) do
    with {:ok, task} <- repo.insert(chset) do
      index(repo, task)
      {:ok, task}
    end
  end

  defp apply_move(repo, chset, old_parent_id) do
    with {:ok, updated} <- repo.update(chset) do
      demote_if_emptied(repo, old_parent_id, updated.parent_id)
      index(repo, updated)
      {:ok, updated}
    end
  end

  defp index(repo, %Task{} = task) do
    Links.sync(repo, "task", task.id, task.description)
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
    Links.purge(repo, "task", task.id)

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
  def transition_task(%Task{} = task, event) when is_atom(event) do
    transition_task(task, event, %{})
  end

  @impl true
  def transition_task(%Task{} = task, event, attrs) when is_map(attrs) do
    with :ok <- require_work(task),
         {:ok, _next} <- allowed_transition(task, event),
         :ok <- require_assignee(task, event),
         {:ok, attrs} <- complete_attrs(event, attrs) do
      task
      |> Task.transition_changeset(event, attrs)
      |> Repo.update()
    end
  end

  @doc """
  Files a task document as this project's work breakdown.

  The other end of `RintoPMO.Documents.decompose_document/1`: that turned a
  plan into a document somebody could read and argue with, and this turns the
  document they settled on into the work itself. Between the two sits the only
  gate that matters -- somebody adopted it.

  ## What it makes

  A chunk with tasks under it becomes a summary covering them; a chunk with
  none becomes one piece of work. Nothing else is read out of the document:
  no estimates, because how long something takes is decided by whoever is
  going to do it, and no ordering beyond the order they were written in, which
  is the order they come back in.

  Every task points at the **source** document rather than at the breakdown --
  `document_id` is the spec somebody implements against, and that is the design
  that was broken down, not the list of work it produced. A breakdown written
  by hand has no source, and its tasks point at nothing, which is allowed.

  ## Once, and all of it

  The document has to be `:formal` and comes out `:applied`, so a second call
  is refused rather than filing the same breakdown twice. Tasks and that
  transition are one transaction: either the work exists and the document is
  spent, or neither happened and the document is still there to fix and file.

  Changing what got filed is not this function's business and never becomes
  it. Editing the document afterwards changes nothing here, deliberately --
  see `docs/implementation-plan-task-decomposition.md`. Work that turns out to
  be wrong is cancelled; work that is missing comes from breaking down another
  document.
  """
  @impl true
  def file_breakdown(%Document{} = breakdown) do
    with {:ok, chunks} <- read_breakdown(breakdown) do
      chunks
      |> file(breakdown, documents().source_of(breakdown))
      |> unwrap_refusal()
    end
  end

  # The work and the document's last state move together or not at all.
  defp file(chunks, %Document{} = breakdown, spec) do
    Repo.transact(fn repo ->
      with {:ok, filed} <- insert_chunks(chunks, breakdown, spec, repo),
           {:ok, _applied} <- documents().apply_document(breakdown) do
        {:ok, filed}
      end
    end)
  end

  # Refused here as well as by `apply_document/1` inside the transaction. The
  # one inside is the guarantee; this one is so that a person who clicked the
  # wrong button is told which document and what state, rather than getting a
  # changeset error about a field they never sent.
  defp read_breakdown(%Document{status: :formal} = breakdown) do
    breakdown.id
    |> documents().get_document!()
    |> Map.fetch!(:latest_revision)
    |> Map.fetch!(:blocks)
    |> Breakdown.parse()
  end

  defp read_breakdown(%Document{status: status}) do
    {:error, :document_not_formal, %{status: status}}
  end

  # Answered flat, in the order things were written, with `parent_id` on every
  # row -- the same shape `list_tasks/2` gives and for the same reason: a
  # caller that wants the tree builds it once, and one that wants a queue is
  # not made to unpick a tree first.
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

  # A chunk nobody broke down further is one job, not a cover over one job.
  # Writing it as a `##` with no `###` is how the document says so.
  defp insert_chunk(%{tasks: []} = chunk, breakdown, spec, repo) do
    with {:ok, task} <- insert_node(chunk, :work, breakdown, spec, repo), do: {:ok, [task]}
  end

  defp insert_chunk(chunk, breakdown, spec, repo) do
    with {:ok, summary} <- insert_node(chunk, :summary, breakdown, spec, repo) do
      insert_tasks(chunk.tasks, summary, breakdown, spec, repo)
    end
  end

  # The summary leads the list it covers, so what comes back reads in document
  # order whether or not a chunk had tasks under it.
  defp insert_tasks(tasks, summary, breakdown, spec, repo) do
    tasks
    |> Enum.reduce_while({:ok, [summary]}, fn task, {:ok, created} ->
      case insert_node(task, :work, breakdown, spec, repo, summary) do
        {:ok, child} -> {:cont, {:ok, [child | created]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, created} -> {:ok, Enum.reverse(created)}
      error -> error
    end
  end

  defp insert_node(node, kind, %Document{} = breakdown, spec, repo, parent \\ nil) do
    %Task{project_id: breakdown.project_id, parent_id: parent && parent.id}
    |> Task.creation_changeset(%{
      kind: kind,
      title: node.title,
      description: node.description,
      document_id: spec && spec.id
    })
    |> repo.insert()
  end

  # Which heading failed, said the way the document says it. An index into a
  # list nobody wrote as a list would send somebody counting blocks.
  defp chunk_errors(chunk, chset) do
    %{"chunk" => chunk.title, "errors" => Changeset.traverse_errors(chset, &elem(&1, 0))}
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
    with {:ok, attrs} <- put_estimate(attrs),
         {:ok, attrs} <- put_difficulty(attrs),
         {:ok, attrs} <- put_actual(attrs) do
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

  @doc """
  Asks a model to fill in what this subtree is missing.

  `:difficulty` rates work in Fibonacci story points; `:time` produces a
  three-point estimate, calibrated with completed work from the same project.
  One function and not two, because the two differ in the question put to the
  model and in nothing else: same target, same targeting, same refusals, same
  answer.

  The target is one node. A work item is estimated itself; a summary is
  estimated as the work under it that still has no value. Answers with the
  *job*, before the model has been asked -- the call takes as long as it takes.

  Refused when there is nothing left to estimate, or when nobody holds the
  `estimation_actor` role. Both are answered here, synchronously, because both
  are conditions of asking rather than outcomes of the answer.

  Asking twice is not refused. This is a helper for somebody who has an empty
  field and does not feel like filling it in, so a second ask is a second ask;
  it overwrites, and neither answer claims to be the better one. What it does
  not do is fire twice for one double-click: while a job of this kind is still
  in flight on this task, `Oban` hands back the job already queued.

  The two kinds are separate slots. One of each may be in flight on the same
  task -- they are different questions.
  """
  @impl true
  def request_estimation(%Task{} = task, kind) when kind in @estimation_kinds do
    with :ok <- something_to_estimate(task, kind),
         {:ok, _actor} <- estimation_actor() do
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

  defp something_to_estimate(%Task{} = task, kind) do
    case subtree_work(task) do
      [] ->
        {:error, :nothing_to_estimate, %{kind: kind, reason: "no work items to estimate"}}

      work ->
        case unfilled(work, kind) do
          [] ->
            {:error, :nothing_to_estimate,
             %{kind: kind, reason: nothing_to_estimate_reason(kind)}}

          _targets ->
            :ok
        end
    end
  end

  defp nothing_to_estimate_reason(:difficulty),
    do: "every work item already has a difficulty"

  defp nothing_to_estimate_reason(:time),
    do: "every work item already has an estimate"

  defp unfilled_work(%Task{} = task, kind), do: unfilled(subtree_work(task), kind)

  defp unfilled(tasks, :difficulty), do: Enum.filter(tasks, &is_nil(&1.difficulty))
  defp unfilled(tasks, :time), do: Enum.filter(tasks, &is_nil(&1.estimate_optimistic))

  defp subtree_work(%Task{kind: :work} = task), do: [task]

  defp subtree_work(%Task{kind: :summary} = task) do
    children = Enum.group_by(project_tasks(task.project_id), & &1.parent_id)
    collect_work(task.id, children)
  end

  defp collect_work(id, children) do
    children
    |> Map.get(id, [])
    |> Enum.flat_map(fn
      %Task{kind: :work} = task -> [task]
      %Task{kind: :summary, id: child_id} -> collect_work(child_id, children)
    end)
  end

  defp estimation_actor do
    case Settings.get_actor("estimation_actor") do
      nil -> {:error, :no_estimation_actor, %{}}
      actor -> {:ok, actor}
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
    with {:ok, actor} <- estimation_actor(),
         {:ok, items} <- call_estimator(kind, task, targets, actor) do
      case apply_estimation(kind, targets, items) do
        0 -> fail(job_id, task.id, kind, "the model did not estimate any of the tasks")
        _count -> succeed(job_id, task.id, kind)
      end
    else
      {:error, :no_estimation_actor, _details} ->
        fail(job_id, task.id, kind, "no actor holds the estimation role")

      {:error, reason} ->
        fail(job_id, task.id, kind, failure_reason(reason))
    end
  end

  defp call_estimator(kind, %Task{} = task, targets, actor) do
    opts = [
      provider: actor.provider,
      model: actor.model,
      thinking: actor.thinking_level
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
    |> where([task], task.kind == :work)
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
      {:ok, attrs} -> task |> Task.changeset(attrs) |> Repo.update()
      _invalid -> :invalid
    end
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
          unestimated_tasks: Enum.sum_by(rolled, &count_unestimated/1),
          unrated_tasks: Enum.sum_by(rolled, &count_unrated/1),
          unmeasured_tasks: Enum.sum_by(rolled, &count_unmeasured/1)
      }
      |> put_summed_estimate(rolled)
      |> put_summed_actual(rolled)
    end
  end

  defp count_unestimated(%Task{kind: :summary} = task), do: task.unestimated_tasks
  defp count_unestimated(%Task{estimate_optimistic: nil}), do: 1
  defp count_unestimated(%Task{}), do: 0

  defp count_unrated(%Task{kind: :summary} = task), do: task.unrated_tasks
  defp count_unrated(%Task{difficulty: nil}), do: 1
  defp count_unrated(%Task{}), do: 0

  defp count_unmeasured(%Task{kind: :summary} = task), do: task.unmeasured_tasks
  defp count_unmeasured(%Task{actual_minutes: nil}), do: 1
  defp count_unmeasured(%Task{}), do: 0

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

  # Summed over the descendants that actually carry one. Same rule as the
  # estimate: a cover with nothing measured under it reports no actual rather
  # than zero, because zero is a claim that the chunk took no time.
  defp put_summed_actual(%Task{} = task, rolled) do
    case Enum.reject(rolled, &is_nil(&1.actual_minutes)) do
      [] ->
        task

      measured ->
        %{task | actual_minutes: Enum.sum_by(measured, & &1.actual_minutes)}
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

  defp kind_of(attrs) do
    case attrs |> stringify_keys() |> Map.get("kind") do
      kind when kind in ["summary", :summary] -> :summary
      _other -> :work
    end
  end

  @difficulties [1, 2, 3, 5, 8, 13, 21]

  defp put_difficulty(attrs, kind \\ :work) do
    attrs = stringify_keys(attrs)

    case Map.fetch(attrs, "difficulty") do
      :error ->
        {:ok, attrs}

      {:ok, nil} ->
        {:ok, attrs}

      {:ok, _value} when kind == :summary ->
        {:error, :invalid_difficulty,
         %{field: "difficulty", reason: "a summary node does not carry a difficulty"}}

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

  defp put_actual(attrs, kind \\ :work) do
    attrs = stringify_keys(attrs)

    case Map.fetch(attrs, "actual_minutes") do
      :error ->
        {:ok, attrs}

      {:ok, nil} ->
        {:ok, attrs}

      {:ok, _value} when kind == :summary ->
        {:error, :invalid_actual,
         %{
           field: "actual_minutes",
           reason: "a summary node takes its actual duration from its children"
         }}

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
