defmodule RintoPMO.Requirements do
  @moduledoc """
  Project-scoped requirements, with editable drafts and retained archive history.
  """
  use RintoPMO, :context

  alias RintoPMO.Projects.Project
  alias RintoPMO.Requirements.Requirement
  alias RintoPMO.Requirements.Workload
  alias RintoPMO.Tasks.Task

  @spec list_requirements(Project.t() | :all, UUIDv7.t() | nil | :all) :: [Requirement.t()]
  def list_requirements(project, parent_id \\ nil) do
    Requirement
    |> project_scope(project)
    |> where([requirement], is_nil(requirement.archived_at))
    |> parent_scope(parent_id)
    |> order_by([requirement], desc: requirement.inserted_at, desc: requirement.id)
    |> with_child_counts()
    |> Repo.all()
    |> Workload.load()
  end

  @spec get_requirement!(Project.t(), UUIDv7.t()) :: Requirement.t()
  def get_requirement!(%Project{id: project_id}, id) do
    Requirement
    |> with_child_counts()
    |> preload(:project)
    |> Repo.get_by!(id: id, project_id: project_id)
    |> Workload.load()
  end

  @spec get_requirement!(UUIDv7.t()) :: Requirement.t()
  def get_requirement!(id) do
    Requirement |> with_child_counts() |> preload(:project) |> Repo.get!(id) |> Workload.load()
  end

  @spec create_requirement(Project.t(), map()) ::
          {:ok, Requirement.t()} | {:error, Ecto.Changeset.t()}
  def create_requirement(%Project{} = project, attrs) do
    Repo.transact(fn ->
      current_project = Repo.get!(Project, project.id)

      %Requirement{project_id: project.id}
      |> Requirement.creation_changeset(attrs)
      |> validate_project(current_project)
      |> put_parent(attrs)
      |> Repo.insert()
    end)
  end

  @spec update_requirement(Requirement.t(), map()) ::
          {:ok, Requirement.t()} | {:error, Ecto.Changeset.t()}
  def update_requirement(%Requirement{} = requirement, attrs) do
    Repo.transact(fn ->
      current = lock_requirement!(requirement)
      project = Repo.get!(Project, current.project_id)

      with {:ok, updated} <-
             current
             |> Requirement.changeset(attrs)
             |> validate_project(project)
             |> validate_editable(current)
             |> Repo.update() do
        {:ok, get_requirement!(project, updated.id)}
      end
    end)
  end

  @spec archive_requirement(Requirement.t()) ::
          {:ok, Requirement.t()} | {:error, Ecto.Changeset.t()}
  def archive_requirement(%Requirement{} = requirement) do
    Repo.transact(fn ->
      current = lock_requirement!(requirement)

      current
      |> Ecto.Changeset.change(archived_at: current.archived_at || DateTime.utc_now())
      |> validate_archivable(current)
      |> Repo.update()
    end)
  end

  defp project_scope(query, :all), do: preload(query, :project)

  defp project_scope(query, %Project{id: project_id}),
    do: where(query, [requirement], requirement.project_id == ^project_id)

  defp parent_scope(query, :all), do: query
  defp parent_scope(query, nil), do: where(query, [requirement], is_nil(requirement.parent_id))
  defp parent_scope(query, id), do: where(query, [requirement], requirement.parent_id == ^id)

  defp with_child_counts(query) do
    counts =
      from child in Requirement,
        where: not is_nil(child.parent_id) and is_nil(child.archived_at),
        group_by: child.parent_id,
        select: %{parent_id: child.parent_id, count: count(child.id)}

    from requirement in query,
      left_join: children in subquery(counts),
      on: children.parent_id == requirement.id,
      select_merge: %{child_count: coalesce(children.count, 0)}
  end

  # Create-only assignment keeps existing subtrees stable. A new row points
  # only to an existing row, so API callers cannot introduce a cycle.
  defp put_parent(changeset, attrs) do
    case Map.get(attrs, :parent_id, Map.get(attrs, "parent_id")) do
      nil -> changeset
      value -> resolve_parent(changeset, Ecto.UUID.cast(value))
    end
  end

  defp resolve_parent(changeset, :error),
    do: Ecto.Changeset.add_error(changeset, :parent_id, "is invalid")

  defp resolve_parent(changeset, {:ok, id}) do
    project_id = Ecto.Changeset.get_field(changeset, :project_id)

    parent =
      Repo.one(
        from requirement in Requirement,
          where: requirement.id == ^id and requirement.project_id == ^project_id,
          lock: "FOR UPDATE"
      )

    assign_parent(changeset, parent)
  end

  defp assign_parent(changeset, %Requirement{archived_at: nil, status: status} = parent)
       when status in [:draft, :active] do
    if Repo.exists?(from task in Task, where: task.requirement_id == ^parent.id) do
      Ecto.Changeset.add_error(
        changeset,
        :parent_id,
        "already has tasks; only leaf requirements can own tasks"
      )
    else
      Ecto.Changeset.put_change(changeset, :parent_id, parent.id)
    end
  end

  defp assign_parent(changeset, _parent),
    do:
      Ecto.Changeset.add_error(
        changeset,
        :parent_id,
        "must be an open requirement in this project"
      )

  defp validate_archivable(changeset, %Requirement{archived_at: nil, id: id}) do
    children =
      from requirement in Requirement,
        where: requirement.parent_id == ^id and is_nil(requirement.archived_at)

    if Repo.exists?(children),
      do: Ecto.Changeset.add_error(changeset, :children, "archive the remaining children first"),
      else: changeset
  end

  defp validate_archivable(changeset, _requirement), do: changeset

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

  defp validate_editable(changeset, %Requirement{archived_at: nil, status: :active}) do
    if Enum.any?([:title, :description], &Ecto.Changeset.changed?(changeset, &1)) do
      Ecto.Changeset.add_error(
        changeset,
        :status,
        "only priority can be edited on active requirements"
      )
    else
      changeset
    end
  end

  defp validate_editable(changeset, %Requirement{}) do
    Ecto.Changeset.add_error(changeset, :status, "only unarchived drafts can be edited")
  end
end
