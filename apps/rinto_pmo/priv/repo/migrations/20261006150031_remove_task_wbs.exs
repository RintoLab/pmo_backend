defmodule RintoPMO.Repo.Migrations.RemoveTaskWbs do
  use Ecto.Migration

  def up do
    # The preceding requirement migration clears the old task corpus on upgrade.
    # Also discard any remaining WBS containers in already-migrated installations.
    execute(
      "DELETE FROM links WHERE source_type = 'task' AND source_id IN (SELECT id FROM tasks WHERE kind = 'summary')"
    )

    execute("DELETE FROM tasks WHERE kind = 'summary'")

    drop constraint(:tasks, :tasks_summary_holds_no_work_check)
    drop constraint(:tasks, :tasks_kind_check)
    drop index(:tasks, [:parent_id])
    drop index(:tasks, [:project_id], name: :tasks_claimable_index)
    drop index(:tasks, [:planned_start_on], name: :tasks_scheduled_index)

    alter table(:tasks) do
      remove :parent_id
      remove :kind
    end

    create index(:tasks, [:project_id],
             where: "assignee_id IS NULL AND status IN ('open', 'in_progress')",
             name: :tasks_claimable_index
           )

    create index(:tasks, [:planned_start_on],
             where: "planned_start_on IS NOT NULL AND status IN ('open', 'in_progress')",
             name: :tasks_scheduled_index
           )
  end

  def down do
    raise "task WBS removal cannot restore discarded task hierarchy"
  end
end
