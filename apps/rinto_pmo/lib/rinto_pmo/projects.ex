defmodule RintoPMO.Projects do
  @moduledoc """
  The context for projects and their repository configurations.

  ## The default project

  One slug is reserved: `"personal"`. `mix rinto.actors.setup_human` creates it
  alongside the person who operates the system, and a document created without
  a project lands in it (see `RintoPMO.Documents.create_document/1`).

  It is an ordinary project in every other way -- it can hold repositories, be
  renamed, and be archived. Only its slug is load-bearing, and no project's slug
  can change after creation (`RintoPMO.Projects.Project` says why), so the way
  to lose the default project is to archive or delete it rather than to rename
  it out from under the documents that land in it.
  """

  use RintoPMO, :context

  require Logger

  alias RintoPMO.Projects.Project
  alias RintoPMO.Projects.ProjectRepo
  alias RintoPMO.Workspace

  @default_slug "personal"

  defmodule Behaviour do
    @moduledoc false

    alias RintoPMO.Projects.Project
    alias RintoPMO.Projects.ProjectRepo

    @callback list_projects() :: [Project.t()]
    @callback get_default_project() :: Project.t() | nil
    @callback get_project_by_slug!(String.t()) :: Project.t()
    @callback get_active_project_by_slug!(String.t()) :: Project.t()
    @callback create_project(map()) :: {:ok, Project.t()} | {:error, Ecto.Changeset.t()}
    @callback update_project(Project.t(), map()) ::
                {:ok, Project.t()} | {:error, Ecto.Changeset.t()}
    @callback archive_project(Project.t()) ::
                {:ok, Project.t()} | {:error, Ecto.Changeset.t()}

    @callback list_project_repos(Project.t()) :: [ProjectRepo.t()]
    @callback get_project_repo!(Project.t(), UUIDv7.t()) :: ProjectRepo.t()
    @callback create_project_repo(Project.t(), map()) ::
                {:ok, ProjectRepo.t()} | {:error, Ecto.Changeset.t()}
    @callback update_project_repo(ProjectRepo.t(), map()) ::
                {:ok, ProjectRepo.t()} | {:error, Ecto.Changeset.t()}
    @callback delete_project_repo(ProjectRepo.t()) ::
                {:ok, ProjectRepo.t()} | {:error, Ecto.Changeset.t()}
  end

  @behaviour Behaviour

  @doc """
  Lists active projects.
  """
  @impl true
  def list_projects do
    Project
    |> where([project], project.status == :active)
    |> order_by([project], asc: project.name)
    |> Repo.all()
  end

  @doc """
  The slug the default project is found by.
  """
  @spec default_slug() :: String.t()
  def default_slug, do: @default_slug

  @doc """
  The project a document with no project of its own belongs to, or `nil`.

  Archived counts. Archiving is about a project being finished rather than
  gone, and refusing to file a note in it would be a strange way to find that
  out -- the person archived it, and the alternative is a document belonging
  nowhere.
  """
  @impl true
  def get_default_project do
    Repo.get_by(Project, slug: @default_slug)
  end

  @doc """
  Fetches an active or archived project by slug and preloads its repositories.
  """
  @impl true
  def get_project_by_slug!(slug) do
    repos_query = from project_repo in ProjectRepo, order_by: [asc: project_repo.name]

    Project
    |> where([project], project.slug == ^slug)
    |> Repo.one!()
    |> Repo.preload(repos: repos_query)
  end

  @doc """
  Fetches an active project by slug.
  """
  @impl true
  def get_active_project_by_slug!(slug) do
    Project
    |> where([project], project.slug == ^slug and project.status == :active)
    |> Repo.one!()
  end

  @doc """
  Creates an active project.
  """
  @impl true
  def create_project(attrs) do
    attrs
    |> Project.create_changeset()
    |> Repo.insert()
  end

  @doc """
  Updates project metadata.

  Neither status nor slug is accepted: status has `archive_project/1`, and the
  slug is fixed at creation because bodies address projects by it. See
  `RintoPMO.Projects.Project`.
  """
  @impl true
  def update_project(%Project{} = project, attrs) do
    project
    |> Project.update_changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Idempotently archives a project rather than deleting it.
  """
  @impl true
  def archive_project(%Project{} = project) do
    project
    |> Project.archive_changeset()
    |> Repo.update()
  end

  @doc """
  Lists repositories for an active project.
  """
  @impl true
  def list_project_repos(%Project{} = project) do
    project
    |> Ecto.assoc(:repos)
    |> order_by([project_repo], asc: project_repo.name)
    |> Repo.all()
  end

  @doc """
  Fetches a repository scoped to an active project.
  """
  @impl true
  def get_project_repo!(%Project{} = project, id) do
    project
    |> Ecto.assoc(:repos)
    |> where([project_repo], project_repo.id == ^id)
    |> Repo.one!()
  end

  @doc """
  Creates a repository under an active project.

  Queues the first clone, so that a wrong URL or a wrong credential is visible
  in `last_sync_error` shortly after registering rather than in the middle of
  the first conversation about the project. Installations with no workspace
  configured queue nothing.

  Only `git_url` has to be given. A registration that names no repository gets
  one derived from its URL -- see `RintoPMO.Projects.ProjectRepo.suggest_name/1`
  for why the field exists at all, and `ProjectRepo` for what happens to the
  branch.
  """
  @impl true
  def create_project_repo(%Project{} = project, attrs) do
    with {:ok, project_repo} <- insert_project_repo(project, attrs, 1) do
      queue_first_sync(project_repo)
      {:ok, project_repo}
    end
  end

  # Two registrations racing derive the same name and one of them loses to
  # `project_repos_project_id_name_index`. Retried rather than reported: the
  # caller never chose this name and has nothing to fix in the request. A name
  # that *was* sent is a different matter and comes back as the conflict it is,
  # which is why the retry turns on whether `name_project_repo/2` changed
  # anything.
  @name_attempts 3

  defp insert_project_repo(%Project{} = project, attrs, attempt) do
    named = name_project_repo(project, attrs)

    %ProjectRepo{project_id: project.id}
    |> ProjectRepo.changeset(named)
    |> Repo.insert()
    |> case do
      {:error, changeset} when attempt < @name_attempts ->
        if named != attrs and name_taken?(changeset) do
          insert_project_repo(project, attrs, attempt + 1)
        else
          {:error, changeset}
        end

      result ->
        result
    end
  end

  defp name_taken?(%Ecto.Changeset{errors: errors}) do
    Enum.any?(errors, fn
      {:name, {_message, meta}} -> Keyword.get(meta, :constraint) == :unique
      _other -> false
    end)
  end

  defp name_project_repo(project, attrs) do
    if blank?(attr(attrs, :name)) do
      name =
        attrs
        |> attr(:git_url)
        |> ProjectRepo.suggest_name()
        |> unique_name(project)

      put_attr(attrs, :name, name)
    else
      attrs
    end
  end

  # Names are unique per project, and two repositories in one project routinely
  # share a last URL segment -- a fork and its upstream, `acme/api` next to
  # `beta/api`. Suffixed rather than refused, because nobody asked for this name
  # in the first place. Running out of suffixes falls back to the bare name and
  # lets the unique constraint answer, which is the one case where telling the
  # caller to choose a name is the right answer.
  @name_suffixes 2..1_000

  defp unique_name(base, project) do
    taken = taken_names(project)

    [base]
    |> Stream.concat(Stream.map(@name_suffixes, &"#{base}-#{&1}"))
    |> Enum.find(base, &(not MapSet.member?(taken, &1)))
  end

  defp taken_names(project) do
    project
    |> Ecto.assoc(:repos)
    |> select([project_repo], project_repo.name)
    |> Repo.all()
    |> MapSet.new()
  end

  # Attributes arrive string-keyed from the API and atom-keyed from everything
  # else, and Ecto refuses a map that mixes the two -- so a key added here has
  # to match what is already in there.
  defp attr(attrs, key), do: Map.get(attrs, key) || Map.get(attrs, Atom.to_string(key))

  defp put_attr(attrs, key, value) do
    if attrs |> Map.keys() |> Enum.all?(&is_atom/1) do
      Map.put(attrs, key, value)
    else
      Map.put(attrs, Atom.to_string(key), value)
    end
  end

  defp blank?(nil), do: true
  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(_present), do: false

  # The repository is worth more than its working copy. A queue that will not
  # take the job leaves the row with nothing cloned, which `POST
  # .../repos/:id/checkout` fixes whenever somebody asks.
  defp queue_first_sync(%ProjectRepo{} = project_repo) do
    case Workspace.request_sync(project_repo) do
      {:ok, _job} ->
        :ok

      {:error, :not_configured} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "could not queue the first clone of #{project_repo.id}: #{inspect(reason)}"
        )

        :ok
    end
  end

  @doc """
  Updates a repository that has already been scoped through its project.
  """
  @impl true
  def update_project_repo(%ProjectRepo{} = project_repo, attrs) do
    project_repo
    |> ProjectRepo.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Deletes a repository that has already been scoped through its project.
  """
  @impl true
  def delete_project_repo(%ProjectRepo{} = project_repo) do
    Repo.delete(project_repo)
  end
end
