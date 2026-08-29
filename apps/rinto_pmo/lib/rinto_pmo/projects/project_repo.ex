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

  # Hygiene rather than safety. The workspace addresses a repository by id
  # precisely so that this name can be edited without orphaning a directory
  # (`RintoPMO.Workspace`), so nothing downstream depends on its shape -- but it
  # is what a person types to ask for a repository and what the CLI prints back,
  # and a name that starts with a dash or a dot reads as a mistake wherever it
  # appears.
  @name ~r{\A[A-Za-z0-9][A-Za-z0-9._-]*\z}

  @doc false
  def changeset(%__MODULE__{} = project_repo, attrs) do
    project_repo
    |> cast(attrs, [:name, :git_url, :branch, :credential_id])
    |> validate_required([:name, :git_url, :branch])
    |> validate_format(:name, @name,
      message: "must start with a letter or digit and contain only letters, digits, . _ -"
    )
    |> validate_git_url()
    |> validate_https_when_credential_present()
    |> foreign_key_constraint(:project_id)
    |> foreign_key_constraint(:credential_id)
    |> unique_constraint(:name, name: :project_repos_project_id_name_index)
  end

  @doc """
  Records what a synchronisation found.

  Separate from `changeset/2` because these two columns are not configuration:
  `RintoPMO.Workspace` is the only thing that writes them, and nothing offered
  at the API boundary should be able to claim a repository is current.
  """
  @spec sync_changeset(t(), map()) :: Ecto.Changeset.t()
  def sync_changeset(%__MODULE__{} = project_repo, attrs) do
    cast(project_repo, attrs, [:last_synced_at, :last_sync_error])
  end

  defp validate_git_url(changeset) do
    validate_change(changeset, :git_url, fn :git_url, git_url ->
      case URI.parse(git_url) do
        %URI{scheme: scheme, host: host}
        when is_binary(scheme) and scheme != "" and is_binary(host) and host != "" ->
          []

        _invalid ->
          [git_url: "must be a valid URI"]
      end
    end)
  end

  defp validate_https_when_credential_present(changeset) do
    credential_id = get_field(changeset, :credential_id)
    git_url = get_field(changeset, :git_url)

    cond do
      is_nil(credential_id) or is_nil(git_url) ->
        changeset

      https_url?(git_url) ->
        changeset

      true ->
        add_error(changeset, :git_url, "must use HTTPS when credential_id is set")
    end
  end

  defp https_url?(git_url) do
    case URI.parse(git_url) do
      %URI{scheme: "https"} -> true
      _other -> false
    end
  end
end
