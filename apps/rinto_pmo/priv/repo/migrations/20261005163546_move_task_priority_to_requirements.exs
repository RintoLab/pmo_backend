defmodule RintoPMO.Repo.Migrations.MoveTaskPriorityToRequirements do
  use Ecto.Migration

  # Intentionally discard the draft backlog. Keep documents, requirements and
  # incoming references, which continue to identify the removed work.
  def up do
    execute("DELETE FROM links WHERE source_type = 'task'")

    execute("""
    UPDATE oban_jobs SET state = 'cancelled', cancelled_at = timezone('UTC', now())
    WHERE worker = 'RintoPMO.Tasks.EstimationWorker'
      AND state IN ('available', 'scheduled', 'retryable', 'executing')
    """)

    execute("DELETE FROM tasks")

    alter table(:requirements) do
      add :priority, :integer, null: false, default: 3
    end

    create constraint(:requirements, :requirements_priority_check,
             check: "priority BETWEEN 1 AND 5"
           )

    drop constraint(:tasks, :tasks_priority_check)

    alter table(:tasks) do
      remove :priority

      add :requirement_id, references(:requirements, type: :binary_id, on_delete: :restrict),
        null: false
    end

    create index(:tasks, [:requirement_id])
  end

  # This restores the schema only; deleted tasks cannot be recovered by rollback.
  def down do
    drop index(:tasks, [:requirement_id])

    alter table(:tasks) do
      remove :requirement_id
      add :priority, :integer, null: false, default: 3
    end

    create constraint(:tasks, :tasks_priority_check, check: "priority BETWEEN 1 AND 5")
    drop constraint(:requirements, :requirements_priority_check)

    alter table(:requirements) do
      remove :priority
    end
  end
end
