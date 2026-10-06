defmodule RintoPMO.Repo.Migrations.BindTasksToRepos do
  use Ecto.Migration

  def up do
    alter table(:tasks) do
      add :repo_id, references(:project_repos, type: :binary_id, on_delete: :restrict)
    end

    # Existing work can only be assigned automatically when the project has
    # exactly one repository. Never guess between repositories or discard work.
    execute("""
    UPDATE tasks SET repo_id = repos.id
    FROM project_repos repos
    WHERE repos.project_id = tasks.project_id
      AND (SELECT count(*) FROM project_repos r WHERE r.project_id = tasks.project_id) = 1
    """)

    execute("""
    DO $$ BEGIN
      IF EXISTS (SELECT 1 FROM tasks WHERE repo_id IS NULL) THEN
        RAISE EXCEPTION 'Task repository migration needs unambiguous ownership: projects with existing tasks must have exactly one repository. Resolve the draft tasks before retrying.';
      END IF;
    END $$
    """)

    alter table(:tasks) do
      modify :repo_id, :binary_id, null: false
    end

    create index(:tasks, [:repo_id])
  end

  def down do
    drop index(:tasks, [:repo_id])

    alter table(:tasks) do
      remove :repo_id
    end
  end
end
