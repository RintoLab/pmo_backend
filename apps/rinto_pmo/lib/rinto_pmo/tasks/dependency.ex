defmodule RintoPMO.Tasks.Dependency do
  @moduledoc """
  One edge of "this cannot start until that is done".

  `task_id` waits; `depends_on_id` is what it waits for. See the
  `20260824120000_create_task_dependencies` migration for why the edge points
  at the prerequisite and why this is not a `RintoPMO.Links` row.

  ## An edge may cross projects, and a parent may not

  This looks like an inconsistency with `RintoPMO.Tasks.validate_parent/3`,
  which refuses a parent in another project. It is not: the two relations
  answer different questions.

  A parent decides *where a task lives*. The WBS is one project's breakdown,
  and letting a task hang under another project's cover would put one
  project's work inside another project's tree.

  A dependency moves nothing and changes nothing about what a task belongs to.
  It is a scheduling constraint, and scheduling here is deliberately
  cross-project: one capacity pool, one Gantt, a week that spans every project
  its owner is working in. "The release waits on the infrastructure work" is
  the ordinary case for one person running several projects at once, and
  refusing it would be refusing the thing the constraint is for.

  ## A dependency constrains only while it is live

  A prerequisite that is `:done` imposes nothing -- it is done. A prerequisite
  that is `:cancelled` imposes nothing either, which is the less obvious half:
  the alternative is that dropping one task silently freezes everything
  downstream of it forever, and the only way out is to delete an edge that is
  still a true statement about the work. `Task.live_statuses/0` already names
  exactly this set, so the rule reuses it rather than inventing "terminal".

  Both the scheduling gate in `RintoPMO.Tasks` and the packer in
  `RintoPMO.Schedule` read the constraint that way.
  """

  use RintoPMO, :schema

  alias RintoPMO.Tasks.Task

  @type t :: %__MODULE__{}

  schema "task_dependencies" do
    belongs_to :task, Task
    belongs_to :depends_on, Task

    timestamps(updated_at: false)
  end

  @doc false
  def changeset(attrs) do
    %__MODULE__{}
    |> cast(attrs, [:task_id, :depends_on_id])
    |> validate_required([:task_id, :depends_on_id])
    |> foreign_key_constraint(:task_id)
    |> foreign_key_constraint(:depends_on_id)
    |> unique_constraint([:task_id, :depends_on_id])
    |> check_constraint(:depends_on_id,
      name: :task_dependencies_no_self_edge_check,
      message: "a task cannot depend on itself"
    )
  end
end
