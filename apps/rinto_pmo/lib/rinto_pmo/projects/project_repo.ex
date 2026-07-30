defmodule RintoPMO.Projects.ProjectRepo do
  @moduledoc """
  A read-only Git repository configured for a project.

  Repository configuration is writable through its changeset. Synchronization
  results are deliberately managed by the future synchronization subsystem.
  """

  use RintoPMO, :schema

  alias RintoPMO.Projects.Project
  alias RintoPMO.RepoCredentials.RepoCredential

  @type t :: %__MODULE__{}

  schema "project_repos" do
    field :name, :string
    field :git_url, :string
    field :branch, :string
    field :last_synced_at, :utc_datetime_usec
    field :last_sync_error, :string

    belongs_to :project, Project
    belongs_to :credential, RepoCredential

    timestamps()
  end

  @doc false
  def changeset(%__MODULE__{} = project_repo, attrs) do
    project_repo
    |> cast(attrs, [:name, :git_url, :branch, :credential_id])
    |> validate_required([:name, :git_url, :branch])
    |> foreign_key_constraint(:project_id)
    |> foreign_key_constraint(:credential_id)
    |> unique_constraint(:name, name: :project_repos_project_id_name_index)
  end
end
