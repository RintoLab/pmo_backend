defmodule RintoPMO.Tasks.Task do
  @moduledoc "An executable task owned by a leaf requirement and one repository."

  use RintoPMO, :schema

  alias RintoPMO.Actors.Actor
  alias RintoPMO.Documents.Document
  alias RintoPMO.Embeddings
  alias RintoPMO.Projects.Project

  @type t :: %__MODULE__{}
  @type status :: :open | :in_progress | :done | :cancelled
  @type event :: :start | :complete | :cancel | :reopen

  @statuses [:open, :in_progress, :done, :cancelled]
  @live_statuses [:open, :in_progress]
  @difficulties [1, 2, 3, 5, 8, 13, 21]
  @priorities [1, 2, 3, 4, 5]

  # The event table, read as "from this status, this event lands there".
  # Anything absent is a `task_state_conflict`; there is no silent no-op,
  # because "complete" arriving twice from two clients is a fact worth
  # reporting rather than swallowing.
  @transitions %{
    start: %{open: :in_progress},
    complete: %{in_progress: :done},
    # Cancelling reaches every live status: work is abandoned mid-flight at
    # least as often as before it starts.
    cancel: %{open: :cancelled, in_progress: :cancelled},
    # Without `reopen` a mistaken `complete` is permanent, and the only way
    # back is a second task that pretends to be the first one.
    reopen: %{done: :open, cancelled: :open}
  }

  schema "tasks" do
    field :title, :string
    field :description, :string
    field :status, Ecto.Enum, values: @statuses, default: :open
    field :due_on, :date

    # The earliest day this task may be worked, and at the same time the whole
    # of "put it in that iteration". Null is the backlog. Where it actually
    # lands is `RintoPMO.Schedule`'s answer, not this column's.
    field :planned_start_on, :date

    # The day this task was first selected into any week, written once and
    # never moved. `planned_start_on` is the current plan and replanning is
    # what it is for, so it cannot also be the baseline: a task pushed from
    # week 1 to week 6 would read as though week 6 had always been the plan,
    # and the slip -- the one thing worth knowing about it -- disappears at the
    # moment somebody acts on it. Not castable; see `put_first_planned_on/1`.
    field :first_planned_on, :date

    # Filled from the requirement at read time, never copied into this table.
    field :priority, :integer, virtual: true
    field :estimate_optimistic, :integer
    field :estimate_likely, :integer
    field :estimate_pessimistic, :integer

    # Fibonacci story points. Null until somebody (or the estimator) rates it.
    field :difficulty, :integer

    # How long the work actually took, in minutes. Derived from the task's
    # execution clock on completion unless a value was recorded explicitly.
    field :actual_minutes, :integer

    field :assigned_at, :utc_datetime_usec
    field :started_at, :utc_datetime_usec
    field :completed_at, :utc_datetime_usec

    # Null means "needs embedding". Never cast from a caller: it is written
    # by the worker that computes it, and voided by whichever changeset rewrites
    # the title and description it was made from. See `RintoPMO.Embeddings`.
    field :embedding, Pgvector.Ecto.Vector

    belongs_to :project, Project
    belongs_to :requirement, RintoPMO.Requirements.Requirement
    belongs_to :repo, RintoPMO.Projects.ProjectRepo
    belongs_to :document, Document
    belongs_to :assignee, Actor

    timestamps()
  end

  @doc """
  The statuses a task can hold.
  """
  @spec statuses() :: [status()]
  def statuses, do: @statuses

  @doc """
  The statuses that still represent outstanding work.

  What "unfinished" means for the claimable pool, for overdue counting, and for
  anything else that has to tell work left from work behind us.
  """
  @spec live_statuses() :: [status()]
  def live_statuses, do: @live_statuses

  @doc """
  The Fibonacci story points a task can be rated with.
  """
  @spec difficulties() :: [pos_integer()]
  def difficulties, do: @difficulties

  @doc """
  The priority levels a task can carry, highest first.
  """
  @spec priorities() :: [pos_integer()]
  def priorities, do: @priorities

  @doc "Returns tasks with the current priority of their requirement."
  def with_priority(query \\ __MODULE__) do
    import Ecto.Query

    from task in query,
      join: requirement in assoc(task, :requirement),
      select_merge: %{priority: requirement.priority}
  end

  @doc """
  The PERT expected value of a three-point estimate, in minutes.

  `(optimistic + 4 * likely + pessimistic) / 6`, rounded. Nil when the task
  carries no estimate.
  """
  @spec expected(t()) :: non_neg_integer() | nil
  def expected(%__MODULE__{estimate_optimistic: nil}), do: nil

  def expected(%__MODULE__{} = task) do
    round((task.estimate_optimistic + 4 * task.estimate_likely + task.estimate_pessimistic) / 6)
  end

  @doc """
  Returns the status `event` leads to from `status`, or `:error`.
  """
  @spec next_status(status(), event()) :: {:ok, status()} | :error
  def next_status(status, event) do
    @transitions
    |> Map.fetch!(event)
    |> Map.fetch(status)
  end

  @doc false
  def creation_changeset(%__MODULE__{} = task \\ %__MODULE__{}, attrs) do
    task
    |> cast(attrs, [:requirement_id])
    |> common_changes(attrs)
    |> Embeddings.invalidate([:title, :description])
  end

  @doc false
  def changeset(%__MODULE__{} = task \\ %__MODULE__{}, attrs) do
    task
    |> change()
    |> common_changes(attrs)
    |> reject_input(attrs, :requirement_id, "cannot be changed")
    |> Embeddings.invalidate([:title, :description])
  end

  defp common_changes(chset, attrs) do
    chset
    |> cast(attrs, [
      :title,
      :description,
      :document_id,
      :repo_id,
      :assignee_id,
      :due_on,
      :estimate_optimistic,
      :estimate_likely,
      :estimate_pessimistic,
      :difficulty,
      :actual_minutes,
      :planned_start_on
    ])
    |> validate_required([:title, :requirement_id, :repo_id])
    |> validate_length(:title, min: 1, max: 255)
    |> reject_input(attrs, :kind, "is no longer supported; tasks are executable work")
    |> reject_input(attrs, :parent_id, "is no longer supported; use requirement_id")
    |> reject_input(attrs, :priority, "is inherited from the requirement")
    |> put_first_planned_on()
    |> put_assigned_at()
    |> foreign_key_constraint(:project_id)
    |> foreign_key_constraint(:requirement_id)
    |> foreign_key_constraint(:repo_id)
    |> foreign_key_constraint(:document_id)
    |> foreign_key_constraint(:assignee_id)
  end

  defp reject_input(changeset, attrs, field, message) do
    if Map.has_key?(attrs, field) or Map.has_key?(attrs, Atom.to_string(field)),
      do: add_error(changeset, field, message),
      else: changeset
  end

  @doc false
  def assignment_changeset(%__MODULE__{} = task, assignee_id) do
    task
    |> change(assignee_id: assignee_id)
    |> put_assigned_at()
    |> foreign_key_constraint(:assignee_id)
  end

  @doc false
  def transition_changeset(%__MODULE__{} = task, event, attrs \\ %{}) do
    task
    |> change()
    |> apply_event(event, attrs)
  end

  defp apply_event(chset, :start, _attrs),
    do: change(chset, status: :in_progress, started_at: now())

  defp apply_event(chset, :complete, attrs) do
    # One timestamp owns both facts so rounding cannot put the duration and the
    # completion clock on opposite sides of a minute. An explicit value wins;
    # one recorded earlier survives; only a still-empty duration is derived.
    completed_at = now()
    supplied = Map.get(attrs, "actual_minutes", Map.get(attrs, :actual_minutes))

    minutes =
      supplied || chset.data.actual_minutes ||
        elapsed_minutes(chset.data.started_at, completed_at)

    changes = %{status: :done, completed_at: completed_at}

    changes =
      if is_integer(minutes), do: Map.put(changes, :actual_minutes, minutes), else: changes

    change(chset, changes)
  end

  # Cancelling keeps `started_at`: work really was done on it, and the record
  # of that is the difference between "we dropped it" and "we never began".
  # `completed_at` stays nil, because nothing was completed. `actual_minutes`
  # stays too, if anyone recorded what was spent before dropping it.
  defp apply_event(chset, :cancel, _attrs), do: change(chset, status: :cancelled)

  # Reopening says the finish never held, so the timestamps that claimed it did
  # go with it. Leaving `completed_at` behind would make a task that is open
  # and complete at once, and every count built on it would have to pick one.
  # `actual_minutes` is the duration of a finish that did not hold, so it goes
  # too. Difficulty stays: the work is the same work.
  defp apply_event(chset, :reopen, _attrs),
    do: change(chset, status: :open, started_at: nil, completed_at: nil, actual_minutes: nil)

  # Round partial minutes up; a missing start does not invent an actual duration.
  defp elapsed_minutes(nil, _completed_at), do: nil

  defp elapsed_minutes(started_at, completed_at) do
    microseconds = max(DateTime.diff(completed_at, started_at, :microsecond), 0)
    div(microseconds + 59_999_999, 60_000_000)
  end

  # Written the first time a task is selected into a week, and never again.
  # Not on every change of `planned_start_on` -- that is replanning, and the
  # whole point of the column is to survive it. Not cleared when a task goes
  # back to the backlog either: "when did we first say we would do this" does
  # not stop having an answer because we stopped saying it.
  defp put_first_planned_on(chset) do
    case {fetch_change(chset, :planned_start_on), fetch_field!(chset, :first_planned_on)} do
      {{:ok, %Date{} = day}, nil} -> put_change(chset, :first_planned_on, day)
      _already_baselined_or_unchanged -> chset
    end
  end

  # Assignment time tracks the assignee it belongs to: a task handed from one
  # actor to another has been sitting with the *new* one only since the handoff.
  defp put_assigned_at(chset) do
    case fetch_change(chset, :assignee_id) do
      {:ok, nil} -> put_change(chset, :assigned_at, nil)
      {:ok, _assignee_id} -> put_change(chset, :assigned_at, now())
      :error -> chset
    end
  end

  defp now, do: DateTime.utc_now()
end
