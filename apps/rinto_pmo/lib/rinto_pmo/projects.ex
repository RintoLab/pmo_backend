defmodule RintoPMO.Projects do
  @moduledoc """
  The context for projects and their repository configurations.
  """

  use RintoPMO, :context

  alias RintoPMO.Projects.Project
  alias RintoPMO.Projects.ProjectRepo

  defmodule Behaviour do
    @moduledoc false

    alias RintoPMO.Projects.Project
    alias RintoPMO.Projects.ProjectRepo

    @callback list_projects() :: [Project.t()]
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
    |> Project.changeset()
    |> Repo.insert()
  end

  @doc """
  Updates project metadata. Status is not accepted by the changeset.
  """
  @impl true
  def update_project(%Project{} = project, attrs) do
    project
    |> Project.changeset(attrs)
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
  """
  @impl true
  def create_project_repo(%Project{} = project, attrs) do
    %ProjectRepo{project_id: project.id}
    |> ProjectRepo.changeset(attrs)
    |> Repo.insert()
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
