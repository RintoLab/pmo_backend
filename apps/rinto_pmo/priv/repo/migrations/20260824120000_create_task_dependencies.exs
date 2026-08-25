defmodule RintoPMO.Repo.Migrations.CreateTaskDependencies do
  @moduledoc """
  "This cannot start until that is done."

  ## The edge points at the prerequisite

  `task_id` is the work that waits; `depends_on_id` is the work it waits for.
  Named this way round because every question asked of this table starts from
  the waiting task -- can this be scheduled, what is holding it up -- and a
  name that reads backwards at the call site is a name that gets used
  backwards eventually.

  ## Not `links`

  `RintoPMO.Links` indexes the `rinto://` references found in bodies, and its
  own migration says outright that every row there is derivable from the text
  it was read out of -- which is what `mix rinto.index.rebuild` exists to
  prove. A dependency is not derivable from anything; it is a fact somebody
  asserted. Put here it survives a rebuild, and stays out of a table whose
  invariant it would break.

  ## What the database can and cannot enforce

  It can refuse the two local mistakes: an edge from a task to itself, and the
  same edge twice.

  It cannot refuse a cycle, and it cannot refuse a dependency scheduled after
  the work that waits for it. Both are statements about a graph rather than
  about a row, so both live in `RintoPMO.Tasks` -- the first through
  `:digraph`, which rejects the edge that would close a loop and hands back the
  loop it would have closed, and the second through the same gate that guards
  every other cross-row rule here.
  """

  use Ecto.Migration

  def change do
    create table(:task_dependencies, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :task_id,
          references(:tasks, type: :binary_id, on_delete: :delete_all),
          null: false

      add :depends_on_id,
          references(:tasks, type: :binary_id, on_delete: :delete_all),
          null: false

      # No `updated_at`: an edge is asserted or removed, never edited.
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:task_dependencies, [:task_id, :depends_on_id])

    # Both directions are asked about: "what is holding this up" walks one way,
    # "what breaks if I move this" walks the other, and the scheduler walks
    # both while ordering a week.
    create index(:task_dependencies, [:depends_on_id])

    create constraint(:task_dependencies, :task_dependencies_no_self_edge_check,
             check: "task_id <> depends_on_id"
           )
  end
end
