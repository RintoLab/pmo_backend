defmodule RintoPMOWeb.V1.RequirementController do
  use RintoPMOWeb, :controller

  alias RintoPMO.Documents
  alias RintoPMO.Projects
  alias RintoPMO.Requirements

  def schedule(conn, %{"id" => id}) do
    with {:ok, result} <- Requirements.Scheduling.request(id, conn.body_params) do
      render(conn, :schedule, result: result)
    end
  end

  def prioritize(conn, %{"id" => id}) do
    with {:ok, job} <- Requirements.Prioritization.request(id) do
      conn |> put_status(:accepted) |> json(%{data: job})
    end
  end

  def estimate(conn, _params) do
    with {:ok, entries} <- Requirements.Estimation.request(conn.body_params["requirement_ids"]) do
      status = if Enum.any?(entries, & &1.job), do: :accepted, else: :ok
      conn |> put_status(status) |> json(%{data: entries})
    end
  end

  def overview(conn, params) do
    with {:ok, sort} <- sort_filter(params["sort"]),
         {:ok, parent_id} <- parent_filter(:all, params["parent_id"]) do
      render(conn, :index, requirements: Requirements.list_requirements(:all, parent_id, sort))
    end
  end

  def index(conn, %{"project_slug" => slug} = params) do
    project = Projects.get_project_by_slug!(slug)

    with {:ok, sort} <- sort_filter(params["sort"]),
         {:ok, parent_id} <- parent_filter(project, params["parent_id"]) do
      render(conn, :index, requirements: Requirements.list_requirements(project, parent_id, sort))
    end
  end

  defp sort_filter(value) when value in [nil, "created"], do: {:ok, :created}
  defp sort_filter("updated"), do: {:ok, :updated}
  defp sort_filter("priority"), do: {:ok, :priority}
  defp sort_filter(_value), do: {:error, :bad_request, %{sort: ["is invalid"]}}

  defp parent_filter(_project, value) when value in [nil, "none"], do: {:ok, nil}
  defp parent_filter(_project, "all"), do: {:ok, :all}

  defp parent_filter(:all, value) do
    with {:ok, id} <- requirement_id(value, :parent_id) do
      {:ok, Requirements.get_requirement!(id).id}
    end
  end

  defp parent_filter(project, value) do
    case Ecto.UUID.cast(value) do
      {:ok, id} -> {:ok, Requirements.get_requirement!(project, id).id}
      :error -> {:error, :bad_request, %{parent_id: ["is invalid"]}}
    end
  end

  def show(conn, %{"project_slug" => slug, "id" => id}) do
    project = Projects.get_project_by_slug!(slug)
    render_requirement(conn, Requirements.get_requirement!(project, id))
  end

  def show_by_id(conn, %{"id" => value}) do
    with {:ok, id} <- requirement_id(value) do
      render_requirement(conn, Requirements.get_requirement!(id))
    end
  end

  def create_unscoped(conn, _params) do
    attrs = conn.body_params

    with {:ok, project} <- creation_project(attrs),
         {:ok, requirement} <-
           Requirements.create_requirement(project, Map.delete(attrs, "project_slug")) do
      conn |> put_status(:created) |> render_requirement(requirement)
    end
  end

  def create(conn, %{"project_slug" => slug}) do
    project = Projects.get_project_by_slug!(slug)

    with {:ok, requirement} <- Requirements.create_requirement(project, conn.body_params) do
      conn |> put_status(:created) |> render_requirement(requirement)
    end
  end

  def update(conn, %{"project_slug" => slug, "id" => id}) do
    project = Projects.get_project_by_slug!(slug)
    requirement = Requirements.get_requirement!(project, id)

    with {:ok, requirement} <- Requirements.update_requirement(requirement, conn.body_params) do
      render_requirement(conn, requirement)
    end
  end

  def update_by_id(conn, %{"id" => value}) do
    with {:ok, id} <- requirement_id(value),
         {:ok, requirement} <-
           Requirements.update_requirement(Requirements.get_requirement!(id), conn.body_params) do
      render_requirement(conn, requirement)
    end
  end

  def delete(conn, %{"project_slug" => slug, "id" => id}) do
    project = Projects.get_project_by_slug!(slug)
    requirement = Requirements.get_requirement!(project, id)

    with {:ok, _requirement} <- Requirements.archive_requirement(requirement) do
      send_resp(conn, :no_content, "")
    end
  end

  defp creation_project(%{"project_slug" => slug} = attrs)
       when is_binary(slug) and slug != "" do
    if is_nil(attrs["parent_id"]) do
      {:ok, Projects.get_project_by_slug!(slug)}
    else
      {:error, :bad_request, %{parent_id: ["supply project_slug or parent_id, not both"]}}
    end
  end

  defp creation_project(%{"parent_id" => value} = attrs) when not is_nil(value) do
    if Map.has_key?(attrs, "project_slug") do
      {:error, :bad_request, %{project_slug: ["omit project_slug when supplying parent_id"]}}
    else
      with {:ok, id} <- requirement_id(value, :parent_id) do
        {:ok, Requirements.get_requirement!(id).project}
      end
    end
  end

  defp creation_project(_attrs),
    do: {:error, :bad_request, %{project_slug: ["supply project_slug or parent_id"]}}

  defp requirement_id(value, field \\ :id) do
    case Ecto.UUID.cast(value) do
      {:ok, id} -> {:ok, id}
      :error -> {:error, :bad_request, %{field => ["is invalid"]}}
    end
  end

  defp render_requirement(conn, requirement) do
    requirement =
      if Ecto.assoc_loaded?(requirement.project),
        do: requirement,
        else: Requirements.get_requirement!(requirement.id)

    documents = Documents.list_documents(%{requirement_id: requirement.id})
    render(conn, :show, requirement: requirement, documents: documents)
  end
end
