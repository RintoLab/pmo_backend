defmodule RintoPMO.Repo.Migrations.CreateProjectsRepoCredentialsAndProjectRepos do
  use Ecto.Migration

  def change do
    create table(:projects, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :name, :string, null: false
      add :slug, :string, null: false
      add :description, :text, null: false
      add :status, :string, null: false, default: "active"

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:projects, [:slug])

    create constraint(:projects, :projects_status_check,
             check: "status IN ('active', 'archived')"
           )

    create table(:repo_credentials, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :name, :string, null: false
      add :username, :string, null: false
      add :token, :text, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create table(:project_repos, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :project_id,
          references(:projects, type: :binary_id, on_delete: :delete_all),
          null: false

      add :credential_id,
          references(:repo_credentials, type: :binary_id, on_delete: :nilify_all)

      add :name, :string, null: false
      add :git_url, :string, null: false
      add :branch, :string, null: false
      add :last_synced_at, :utc_datetime_usec
      add :last_sync_error, :text

      timestamps(type: :utc_datetime_usec)
    end

    create index(:project_repos, [:project_id])
    create index(:project_repos, [:credential_id])
    create unique_index(:project_repos, [:project_id, :name])
  end
end
