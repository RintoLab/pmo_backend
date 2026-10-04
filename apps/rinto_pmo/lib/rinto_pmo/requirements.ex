defmodule RintoPMO.Requirements do
  @moduledoc """
  Project-scoped requirements, with editable drafts and retained archive history.
  """
  use RintoPMO, :context

  alias RintoPMO.Projects.Project
  alias RintoPMO.Requirements.Requirement

  @spec list_requirements(Project.t()) :: [Requirement.t()]
  def list_requirements(%Project{id: project_id}) do
    Requirement
    |> where([requirement], requirement.project_id == ^project_id)
    |> where([requirement], is_nil(requirement.archived_at))
    |> order_by([requirement], desc: requirement.inserted_at, desc: requirement.id)
    |> Repo.all()
  end

  @spec get_requirement!(Project.t(), UUIDv7.t()) :: Requirement.t()
  def get_requirement!(%Project{id: project_id}, id) do
    Repo.get_by!(Requirement, id: id, project_id: project_id)
  end

  @spec create_requirement(Project.t(), map()) ::
          {:ok, Requirement.t()} | {:error, Ecto.Changeset.t()}
  def create_requirement(%Project{} = project, attrs) do
    %Requirement{project_id: project.id}
    |> Requirement.changeset(attrs)
    |> validate_project(project)
    |> Repo.insert()
  end

  @spec update_requirement(Requirement.t(), map()) ::
          {:ok, Requirement.t()} | {:error, Ecto.Changeset.t()}
  def update_requirement(%Requirement{} = requirement, attrs) do
    Repo.transact(fn ->
      current = lock_requirement!(requirement)
      project = Repo.get!(Project, current.project_id)

      current
      |> Requirement.changeset(attrs)
      |> validate_project(project)
      |> validate_editable(current)
      |> Repo.update()
    end)
  end

  @spec archive_requirement(Requirement.t()) ::
          {:ok, Requirement.t()} | {:error, Ecto.Changeset.t()}
  def archive_requirement(%Requirement{} = requirement) do
    Repo.transact(fn ->
      current = lock_requirement!(requirement)

      current
      |> Ecto.Changeset.change(archived_at: current.archived_at || DateTime.utc_now())
      |> Repo.update()
    end)
  end

  defp lock_requirement!(requirement) do
    Requirement
    |> where([current], current.id == ^requirement.id)
    |> lock("FOR UPDATE")
    |> Repo.one!()
  end

  defp validate_project(changeset, %Project{status: :active}), do: changeset

  defp validate_project(changeset, %Project{}) do
    Ecto.Changeset.add_error(changeset, :project_id, "is archived")
  end

  defp validate_editable(changeset, %Requirement{archived_at: nil, status: :draft}),
    do: changeset

  defp validate_editable(changeset, %Requirement{}) do
    Ecto.Changeset.add_error(changeset, :status, "only unarchived drafts can be edited")
  end
end
