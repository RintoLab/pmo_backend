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

  ## Estimates are three-point, in minutes

  `optimistic` / `likely` / `pessimistic`, all three or none: a half-given
  three-point estimate has no expected value, so it is not a smaller estimate
  but a broken one. `expected/1` is the PERT weighting, `(o + 4m + p) / 6`.

  Minutes because a breakdown sums, and integers sum exactly. Any coarser unit
  would force this domain to decide how long a working day is, which is not its
  business.

  A `:summary` row stores none of it, like everything else that measures work.
  Its estimate is the sum over its descendants, computed on read by
  `RintoPMO.Tasks` and written onto the struct the same way its status is.

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
  alias RintoPMO.Projects.Project

  @type t :: %__MODULE__{}
  @type kind :: :work | :summary
  @type status :: :open | :in_progress | :done | :cancelled
  @type event :: :start | :complete | :cancel | :reopen

  @kinds [:work, :summary]
  @statuses [:open, :in_progress, :done, :cancelled]
  @live_statuses [:open, :in_progress]

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
    field :estimate_optimistic, :integer
    field :estimate_likely, :integer
    field :estimate_pessimistic, :integer

    # How many work descendants under a cover carry no estimate. A count of
    # tasks, not minutes -- the name says `_tasks` because everything else near
    # it is minutes and a bare `unestimated` reads as one. Null on a `:work`
    # row, where the estimate itself answers the question.
    #
    # A summed estimate that quietly skipped half the tree would read as a
    # complete number, which is the one thing an estimate must never do.
    field :unestimated_tasks, :integer, virtual: true
    field :assigned_at, :utc_datetime_usec
    field :started_at, :utc_datetime_usec
    field :completed_at, :utc_datetime_usec

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
  end

  @doc false
  def changeset(%__MODULE__{} = task \\ %__MODULE__{}, attrs) do
    task
    |> change()
    |> common_changes(attrs)
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
      :estimate_pessimistic
    ])
    |> validate_required([:title, :kind])
    |> validate_length(:title, min: 1, max: 255)
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
  end

  @doc false
  def split_changeset(%__MODULE__{} = task) do
    # Everything a cover cannot hold goes at once. `started_at` in particular:
    # a summary's start is whenever its children started, and keeping the old
    # value would date the chunk from before it existed as one. The estimate
    # goes the same way: the chunk is worth what its parts are worth, and a
    # guess made before anyone knew what the parts were is not that.
    change(task,
      kind: :summary,
      status: :open,
      assignee_id: nil,
      assigned_at: nil,
      started_at: nil,
      completed_at: nil,
      estimate_optimistic: nil,
      estimate_likely: nil,
      estimate_pessimistic: nil
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
  def transition_changeset(%__MODULE__{} = task, event) do
    task
    |> change()
    |> apply_event(event)
  end

  defp apply_event(chset, :start), do: change(chset, status: :in_progress, started_at: now())
  defp apply_event(chset, :complete), do: change(chset, status: :done, completed_at: now())

  # Cancelling keeps `started_at`: work really was done on it, and the record
  # of that is the difference between "we dropped it" and "we never began".
  # `completed_at` stays nil, because nothing was completed.
  defp apply_event(chset, :cancel), do: change(chset, status: :cancelled)

  # Reopening says the finish never held, so the timestamps that claimed it did
  # go with it. Leaving `completed_at` behind would make a task that is open
  # and complete at once, and every count built on it would have to pick one.
  defp apply_event(chset, :reopen),
    do: change(chset, status: :open, started_at: nil, completed_at: nil)

  defp reject_work_on_summary(chset) do
    case fetch_field!(chset, :kind) do
      :summary -> validate_assignee_absent(chset)
      :work -> chset
    end
  end

  defp validate_assignee_absent(chset) do
    case fetch_field(chset, :assignee_id) do
      {_source, nil} -> chset
      _present -> add_error(chset, :assignee_id, "a summary node cannot be assigned")
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
