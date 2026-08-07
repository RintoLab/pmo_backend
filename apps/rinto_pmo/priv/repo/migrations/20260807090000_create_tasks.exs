defmodule RintoPMO.Repo.Migrations.CreateTasks do
  use Ecto.Migration

  def change do
    create table(:tasks, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :project_id,
          references(:projects, type: :binary_id, on_delete: :delete_all),
          null: false

      # A task consumes a document, it does not belong to it. Deleting the
      # document it was written against must not take the work item with it.
      add :document_id,
          references(:documents, type: :binary_id, on_delete: :nilify_all)

      add :assignee_id,
          references(:actors, type: :binary_id, on_delete: :nilify_all)

      # The WBS is one tree of one resource, so a summary node is a task row
      # rather than a second table -- otherwise every list, filter, and sort
      # would have to be written twice and unioned.
      #
      # Children outlive a deleted parent as roots. Losing a work item because
      # its folder went away is worse than a flattened tree.
      add :parent_id,
          references(:tasks, type: :binary_id, on_delete: :nilify_all)

      add :kind, :string, null: false, default: "work"
      add :title, :string, null: false
      add :description, :text
      add :status, :string, null: false, default: "open"
      add :due_on, :date

      # Three-point estimation, in minutes. Minutes because a breakdown sums:
      # integers add exactly, and any coarser unit forces a decision about how
      # long a "day" is that this domain has no business making.
      add :estimate_optimistic, :integer
      add :estimate_likely, :integer
      add :estimate_pessimistic, :integer
      add :assigned_at, :utc_datetime_usec
      add :started_at, :utc_datetime_usec
      add :completed_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create constraint(:tasks, :tasks_kind_check, check: "kind IN ('work', 'summary')")

    create constraint(:tasks, :tasks_status_check,
             check: "status IN ('open', 'in_progress', 'done', 'cancelled')"
           )

    # A summary node holds no work of its own, so the columns that record work
    # must stay empty on it. Enforced here rather than only in the changeset:
    # the rollup reads these rows, and a summary carrying an assignee or a
    # start time would make the derived status argue with the row under it.
    create constraint(:tasks, :tasks_summary_holds_no_work_check,
             check: """
             kind <> 'summary' OR (
               assignee_id IS NULL AND assigned_at IS NULL
               AND started_at IS NULL AND completed_at IS NULL
               AND estimate_optimistic IS NULL AND estimate_likely IS NULL
               AND estimate_pessimistic IS NULL
             )
             """
           )

    # All three or none. A half-given three-point estimate has no expected
    # value, so it is not a smaller estimate -- it is a broken one.
    create constraint(:tasks, :tasks_estimate_complete_check,
             check: """
             (estimate_optimistic IS NULL AND estimate_likely IS NULL
              AND estimate_pessimistic IS NULL)
             OR (estimate_optimistic IS NOT NULL AND estimate_likely IS NOT NULL
                 AND estimate_pessimistic IS NOT NULL)
             """
           )

    create constraint(:tasks, :tasks_estimate_ordered_check,
             check: """
             estimate_optimistic IS NULL
             OR (estimate_optimistic >= 0
                 AND estimate_optimistic <= estimate_likely
                 AND estimate_likely <= estimate_pessimistic)
             """
           )

    create index(:tasks, [:project_id, :status])
    create index(:tasks, [:document_id])
    create index(:tasks, [:parent_id])

    # The claimable pool is "this project, real work, nobody on it, unfinished".
    # A partial index keeps that lookup off the finished rows, which are the
    # ones that accumulate forever.
    create index(:tasks, [:project_id],
             where: "kind = 'work' AND assignee_id IS NULL AND status IN ('open', 'in_progress')",
             name: :tasks_claimable_index
           )

    create index(:tasks, [:assignee_id, :status])
  end
end
