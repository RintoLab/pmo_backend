defmodule RintoPMO.Projects.ProjectRepo do
  @moduledoc """
  A read-only Git repository configured for a project.

  Repository configuration is writable through its changeset. Synchronization
  results are deliberately managed by the future synchronization subsystem.

  ## Only the URL has to be supplied

  `git_url` is the one thing nobody else can know. `name` is derived from it by
  `RintoPMO.Projects.create_project_repo/2`, which is the only place that can,
  because uniqueness is per project -- see `suggest_name/1`. A name that was
  given wins.

  ## There is no branch here

  Deliberately. Which branch to read is a question the conversation asks, and a
  column here could only hold a guess made months earlier by somebody who was
  not in that conversation. `RintoPMO.Workspace` takes the branch per checkout
  and falls back to whatever the remote currently calls its default.

  Nothing is lost by not having it: the working copy is a mirror, which holds
  every ref. The branch was never what made a repository available -- only what
  a single checkout asked the mirror for.
  """

  use RintoPMO, :schema

  alias RintoPMO.Projects.Project
  alias RintoPMO.RepoCredentials.RepoCredential

  @type t :: %__MODULE__{}

  schema "project_repos" do
    field :name, :string
    field :git_url, :string
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

  # Anything the name may not contain, and anything it may not start with.
  @unusable ~r{[^A-Za-z0-9._-]+}
  @unusable_start ~r{\A[^A-Za-z0-9]+}

  # A URL whose path says nothing usable -- `https://host/`, `https://host/.git`
  # -- still has to produce something insertable. Rare enough to be worth no
  # cleverness, and the name is editable.
  @fallback_name "repo"

  # A column, so a basename nobody meant as one cannot fail the insert instead
  # of the validation.
  @max_name_length 100

  @doc false
  def changeset(%__MODULE__{} = project_repo, attrs) do
    project_repo
    |> cast(attrs, [:name, :git_url, :credential_id])
    |> validate_required([:name, :git_url])
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
  What to call a repository whose registration did not say.

  The last segment of the URL's path, without `.git` -- which is what the
  repository is called everywhere else, and therefore the only name a person
  would have typed anyway.

  Sanitised to `@name` rather than validated against it: this runs on whatever
  a caller sent, before the changeset has had its say, and it has to return a
  string in every case. It does not make the name unique -- that is per project
  and belongs to `RintoPMO.Projects`.

  ## Examples

      iex> RintoPMO.Projects.ProjectRepo.suggest_name("https://github.com/acme/rinto.git")
      "rinto"

      iex> RintoPMO.Projects.ProjectRepo.suggest_name("https://example.com/")
      "repo"
  """
  @spec suggest_name(term()) :: String.t()
  def suggest_name(git_url) when is_binary(git_url) do
    git_url
    |> URI.parse()
    |> Map.get(:path)
    |> Kernel.||("")
    |> Path.basename()
    |> String.replace_suffix(".git", "")
    |> String.replace(@unusable, "-")
    |> String.replace(@unusable_start, "")
    |> String.slice(0, @max_name_length)
    |> case do
      "" -> @fallback_name
      name -> name
    end
  end

  def suggest_name(_unusable), do: @fallback_name

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
