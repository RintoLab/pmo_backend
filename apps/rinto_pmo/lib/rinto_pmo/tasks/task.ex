defmodule RintoPMO.Tasks.Task do
  @moduledoc """
  One node of a project's work breakdown: either a unit of work or the cover
  over a pile of it.

  A task *consumes* documents, it does not carry the process of editing them --
  that is `RintoPMO.Conversations` plus the working copy in
  `RintoPMO.Documents`. `document_id` is therefore an optional pointer at the
  spec someone implements against, never an ownership edge, which is why the
  document can be deleted and leave the task standing.

  ## `kind` is not a status

  A summary node is a task row, not a second resource: the WBS is one tree, and
  splitting it across two tables would mean writing every list, filter, and
  sort twice. But "is this a cover or a job" is a different question from "how
  far along is it", so it gets a different field.

  It has to. A summary node's status is the most informative thing on it --
  "this whole chunk is in progress" -- and it is *derived* from the children.
  Spending the `status` slot on the value `:summary` would leave that rollup
  with nowhere to live, and a second field would have to be invented to hold
  it.

  So a `:summary` row accepts nothing that acts on work: no assignee, no
  transitions. It moves only because its children moved. Its stored `status`
  column is inert -- `RintoPMO.Tasks` overwrites it with `rollup/1` on every
  read, and the database constraint keeps the work columns null on it.

  `kind` is not settable, and it is not frozen either. It moves both ways, and
  neither direction is a field a client writes:

    * up, through `split_changeset/1`: a job turning out to be three jobs is
      the most ordinary step in a breakdown, and forbidding it would forbid the
      thing a WBS is for. It is an operation rather than a field because the
      flip has a cost -- a cover holds no assignee and no clock, so whatever
      the job had accumulated has to be let go, and that is not something to
      bury inside an edit of the title.

    * down, through `demote_changeset/1`, and never by request: emptying a
      cover un-covers it. `RintoPMO.Tasks` fires this the moment the last child
      leaves, because a childless cover is a node that can neither be worked
      nor roll anything up -- a dead row in the middle of the tree.

  ## Estimates are three-point, in minutes, and capped at a day

  `optimistic` / `likely` / `pessimistic`, all three or none: a half-given
  three-point estimate has no expected value, so it is not a smaller estimate
  but a broken one. `expected/1` is the PERT weighting, `(o + 4m + p) / 6`.

  Minutes because a breakdown sums, and integers sum exactly. Any coarser unit
  would force this domain to decide how long a working day is, which is not its
  business.

  None of the three may exceed `estimate_ceiling/0`, one working day. That is
  not a limit on ambition, it is what makes `RintoPMO.Schedule` total: since no
  work item is larger than a day, no work item can fail to fit in some week,
  and the packer never needs a branch for the task that never lands anywhere.
  A task that wants more than a day is one that was not broken down far enough,
  and `split_changeset/1` is the answer to that.

  ## Scheduling is one column, and it is also the act

  `planned_start_on` says the earliest day the task may be worked. It does not
  say where it lands -- `RintoPMO.Schedule` decides that by filling each
  workday's capacity in priority order, so a task can start later than this
  day, and can spill across days when the day it landed in was already partly
  full.

  Null is the backlog. There is no `:backlog` status, and there must not be
  one: "which slot of the plan is this in" is a many-valued question -- this
  week, three weeks out, nowhere -- and a status enum could hold only two of
  those answers. It is the same rule as `kind` above. Position is not progress.

  An iteration is a week, and it is not stored anywhere: it is an argument to
  the packer, not a row. Nothing about it is scoped to a project either,
  because one person's week spans every project they are working in.

  `priority` is 1 (highest) to 5, defaulting to 3, and never null: "no opinion"
  is "normal". It decides who gets cut when a week is over-filled, so it sorts
  ahead of everything else -- work carried over from last week has no claim to
  jump the queue.

  A `:summary` row holds no `planned_start_on`, for exactly the reason it holds
  no assignee: a week is a claim on somebody's time, and a cover has no
  somebody. It keeps its `priority` -- how much a chunk matters does not change
  by learning that it is three jobs rather than one.

  A `:summary` row stores none of it, like everything else that measures work.
  Its estimate is the sum over its descendants, computed on read by
  `RintoPMO.Tasks` and written onto the struct the same way its status is.

  ## Difficulty is a Fibonacci story point

  `1 / 2 / 3 / 5 / 8 / 13 / 21`, or none. It is a rating of the work, not a
  duration -- duration is the estimate, and this is the knob later estimates
  are calibrated against. It does not sum, so a cover stores none and reports
  none; what it does report is how many work descendants still have no rating.

  ## Actual duration is recorded, not derived

  `actual_minutes` is how long the work took. `started_at` to `completed_at`
  is wall time and counts the night, which is not a calibration sample.
  Minutes, like the estimate, so a cover can sum them. Cleared on reopen, the
  same way `completed_at` is: the finish never held.

  ## Status only moves through `transition_changeset/3`

  Every field that exists to make a status honest -- `started_at`,
  `completed_at` -- is set and cleared by the transition that owns it, and
  neither is castable. Editing a task's wording must not be able to silently
  complete it, the same rule `RintoPMO.Annotations.Annotation` follows for its
  own status.
  """

  use RintoPMO, :schema

  alias RintoPMO.Actors.Actor
  alias RintoPMO.Documents.Document
  alias RintoPMO.Embeddings
  alias RintoPMO.Projects.Project

  @type t :: %__MODULE__{}
  @type kind :: :work | :summary
  @type status :: :open | :in_progress | :done | :cancelled
  @type event :: :start | :complete | :cancel | :reopen

  @kinds [:work, :summary]
  @statuses [:open, :in_progress, :done, :cancelled]
  @live_statuses [:open, :in_progress]
  @difficulties [1, 2, 3, 5, 8, 13, 21]
  @priorities [1, 2, 3, 4, 5]

  # One working day, in minutes. The ceiling on a three-point estimate, and the
  # reason `RintoPMO.Schedule` never has to special-case a task that cannot fit
  # anywhere: no work item is larger than a day.
  @estimate_ceiling 480

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
    field :kind, Ecto.Enum, values: @kinds, default: :work
    field :title, :string
    field :description, :string
    field :status, Ecto.Enum, values: @statuses, default: :open
    field :due_on, :date

    # The earliest day this task may be worked, and at the same time the whole
    # of "put it in that iteration". Null is the backlog. Where it actually
    # lands is `RintoPMO.Schedule`'s answer, not this column's. A cover holds
    # none, like everything else that lays claim to somebody's time.
    field :planned_start_on, :date

    # 1 highest, 3 normal. Not null: "no opinion" is "normal", and unlike an
    # estimate a missing priority says nothing worth counting.
    field :priority, :integer, default: 3
    field :estimate_optimistic, :integer
    field :estimate_likely, :integer
    field :estimate_pessimistic, :integer

    # Fibonacci story points. Null until somebody (or the estimator) rates it.
    # A cover stores none: difficulty does not sum.
    field :difficulty, :integer

    # How long the work actually took, in minutes. Recorded rather than derived
    # from the clocks, and cleared on reopen. A cover stores none and sums on
    # read, the same way as the estimate.
    field :actual_minutes, :integer

    # How many work descendants under a cover carry no estimate. A count of
    # tasks, not minutes -- the name says `_tasks` because everything else near
    # it is minutes and a bare `unestimated` reads as one. Null on a `:work`
    # row, where the estimate itself answers the question.
    #
    # A summed estimate that quietly skipped half the tree would read as a
    # complete number, which is the one thing an estimate must never do.
    field :unestimated_tasks, :integer, virtual: true

    # Same shape, for difficulty and for actual duration. Null on a `:work`
    # row. `unrated_tasks` counts descendants with no story point;
    # `unmeasured_tasks` counts descendants with no `actual_minutes`.
    field :unrated_tasks, :integer, virtual: true
    field :unmeasured_tasks, :integer, virtual: true

    # How many work descendants under a cover are still in the backlog -- no
    # `planned_start_on`, so no week will ever consider them. A cover whose
    # span said "starts in week 12" while half of it was unplanned would be
    # reading as a schedule when it is a fragment of one.
    field :unscheduled_tasks, :integer, virtual: true
    field :assigned_at, :utc_datetime_usec
    field :started_at, :utc_datetime_usec
    field :completed_at, :utc_datetime_usec

    # Null means "needs embedding". Never cast from a caller: it is written
    # by the worker that computes it, and voided by whichever changeset rewrites
    # the title and description it was made from. See `RintoPMO.Embeddings`.
    field :embedding, Pgvector.Ecto.Vector

    belongs_to :project, Project
    belongs_to :document, Document
    belongs_to :assignee, Actor
    belongs_to :parent, __MODULE__

    has_many :children, __MODULE__, foreign_key: :parent_id

    timestamps()
  end

  @doc """
  The kinds a task node can be.
  """
  @spec kinds() :: [kind()]
  def kinds, do: @kinds

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

  @doc """
  The largest a single three-point estimate may be, in minutes.

  One working day. A work item bigger than this was not broken down far
  enough, and `RintoPMO.Tasks.split_task/2` is the answer to that rather than
  a wider day.
  """
  @spec estimate_ceiling() :: pos_integer()
  def estimate_ceiling, do: @estimate_ceiling

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

  @doc """
  The status a summary node takes from the statuses of its children.

  Reads as: a chunk nobody has touched is `:open`; a chunk everyone is done
  with is `:done`; a chunk that was dropped whole is `:cancelled`; anything in
  between is `:in_progress`.

  Two cases are worth spelling out. A mix of `:done` and `:cancelled` rolls up
  to `:done`, not `:cancelled` -- the chunk landed, and the cancelled parts
  were dropped along the way. An empty summary is `:open`, because a cover over
  nothing is a chunk nobody has broken down yet, not a chunk that is finished.
  """
  @spec rollup([status()]) :: status()
  def rollup([]), do: :open

  def rollup(child_statuses) when is_list(child_statuses) do
    cond do
      Enum.all?(child_statuses, &(&1 == :cancelled)) -> :cancelled
      Enum.all?(child_statuses, &(&1 in [:done, :cancelled])) -> :done
      Enum.all?(child_statuses, &(&1 == :open)) -> :open
      true -> :in_progress
    end
  end

  @doc false
  def creation_changeset(%__MODULE__{} = task \\ %__MODULE__{}, attrs) do
    task
    |> cast(attrs, [:kind])
    |> common_changes(attrs)
    |> Embeddings.invalidate([:title, :description])
  end

  @doc false
  def changeset(%__MODULE__{} = task \\ %__MODULE__{}, attrs) do
    task
    |> change()
    |> common_changes(attrs)
    |> Embeddings.invalidate([:title, :description])
  end

  defp common_changes(chset, attrs) do
    chset
    |> cast(attrs, [
      :title,
      :description,
      :document_id,
      :parent_id,
      :assignee_id,
      :due_on,
      :estimate_optimistic,
      :estimate_likely,
      :estimate_pessimistic,
      :difficulty,
      :actual_minutes,
      :planned_start_on,
      :priority
    ])
    |> validate_required([:title, :kind, :priority])
    |> validate_length(:title, min: 1, max: 255)
    |> validate_inclusion(:priority, @priorities)
    |> reject_work_on_summary()
    |> put_assigned_at()
    |> foreign_key_constraint(:project_id)
    |> foreign_key_constraint(:document_id)
    |> foreign_key_constraint(:parent_id)
    |> foreign_key_constraint(:assignee_id)
    |> check_constraint(:kind,
      name: :tasks_summary_holds_no_work_check,
      message: "a summary node cannot hold work"
    )
    |> check_constraint(:priority,
      name: :tasks_priority_check,
      message: "is invalid"
    )
  end

  @doc false
  def split_changeset(%__MODULE__{} = task) do
    # Everything a cover cannot hold goes at once. `started_at` in particular:
    # a summary's start is whenever its children started, and keeping the old
    # value would date the chunk from before it existed as one. The estimate
    # goes the same way: the chunk is worth what its parts are worth, and a
    # guess made before anyone knew what the parts were is not that. Difficulty
    # and actual duration are work measurements too, and leave with them.
    #
    # `planned_start_on` leaves for the same reason as the assignee: the chunk
    # is worked in whatever weeks its children are worked in, and a cover that
    # kept its own slot would be claiming time that the children now claim.
    # `priority` stays -- how much the chunk matters did not change by learning
    # that it is three jobs rather than one.
    change(task,
      kind: :summary,
      status: :open,
      assignee_id: nil,
      assigned_at: nil,
      started_at: nil,
      completed_at: nil,
      planned_start_on: nil,
      estimate_optimistic: nil,
      estimate_likely: nil,
      estimate_pessimistic: nil,
      difficulty: nil,
      actual_minutes: nil
    )
  end

  @doc false
  def demote_changeset(%__MODULE__{} = task) do
    # A cover that lost its last job is a job again, and a job nobody has
    # started: whatever work there was lived in the children that left. The
    # stored status has been inert since the promotion, so it is reset rather
    # than resurrected -- an `in_progress` from before the split coming back to
    # life weeks later would be a claim nobody made.
    change(task, kind: :work, status: :open)
  end

  @doc false
  def assignment_changeset(%__MODULE__{} = task, assignee_id) do
    task
    |> change(assignee_id: assignee_id)
    |> reject_work_on_summary()
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
    # `actual_minutes` is accepted here so finishing and recording how long it
    # took can be one act. Absent means leave whatever was already stored --
    # somebody may have PATCHed it earlier. The value has already been checked
    # by the context; this only writes it.
    minutes = Map.get(attrs, "actual_minutes", Map.get(attrs, :actual_minutes))

    changes = %{status: :done, completed_at: now()}

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

  # A cover holds no assignee and no schedule, which are the same rule twice: an
  # iteration is a claim on somebody's time, and a cover has no somebody.
  defp reject_work_on_summary(chset) do
    case fetch_field!(chset, :kind) do
      :summary ->
        chset
        |> validate_absent(:assignee_id, "a summary node cannot be assigned")
        |> validate_absent(:planned_start_on, "a summary node cannot be scheduled")

      :work ->
        chset
    end
  end

  defp validate_absent(chset, field, message) do
    case fetch_field(chset, field) do
      {_source, nil} -> chset
      _present -> add_error(chset, field, message)
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
