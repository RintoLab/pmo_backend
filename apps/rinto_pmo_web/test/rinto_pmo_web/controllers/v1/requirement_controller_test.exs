defmodule RintoPMOWeb.V1.RequirementControllerTest do
  use RintoPMOWeb.ConnCase, async: true

  alias RintoPMO.Projects
  alias RintoPMO.Repo
  alias RintoPMO.Requirements
  alias RintoPMO.Requirements.Requirement

  setup do
    project = insert(:project)
    {:ok, project: project}
  end

  test "creates a draft without repositories and edits its description", %{
    conn: conn,
    project: project
  } do
    created = post(conn, ~p"/api/v1/projects/#{project.slug}/requirements", %{title: "  第三方登录  "})
    data = json_response(created, 201)["data"]
    id = data["id"]
    assert data["project_id"] == project.id
    assert data["title"] == "第三方登录"
    assert data["description"] == ""
    assert data["status"] == "draft"
    assert data["archived_at"] == nil
    refute Map.has_key?(data, "repo_ids")

    updated =
      patch(conn, ~p"/api/v1/projects/#{project.slug}/requirements/#{id}", %{
        description: "目标与验收背景"
      })

    assert json_response(updated, 200)["data"]["description"] == "目标与验收背景"
    assert json_response(updated, 200)["data"]["title"] == "第三方登录"

    cleared =
      put(conn, ~p"/api/v1/projects/#{project.slug}/requirements/#{id}", %{description: ""})

    assert json_response(cleared, 200)["data"]["description"] == ""
  end

  test "lists only unarchived requirements belonging to the project", %{
    conn: conn,
    project: project
  } do
    other = insert(:project)
    {:ok, first} = Requirements.create_requirement(project, %{title: "First"})
    {:ok, second} = Requirements.create_requirement(project, %{title: "Second"})
    {:ok, hidden} = Requirements.create_requirement(project, %{title: "Archived"})
    {:ok, _archived} = Requirements.archive_requirement(hidden)
    {:ok, _other} = Requirements.create_requirement(other, %{title: "Other project"})

    listed = get(conn, ~p"/api/v1/projects/#{project.slug}/requirements")
    assert Enum.map(json_response(listed, 200)["data"], & &1["id"]) == [second.id, first.id]
  end

  test "rejects blank titles, overlong titles and null descriptions", %{
    conn: conn,
    project: project
  } do
    for attrs <- [
          %{},
          %{title: " \n "},
          %{title: String.duplicate("x", 256)},
          %{title: "OK", description: nil}
        ] do
      invalid = post(conn, ~p"/api/v1/projects/#{project.slug}/requirements", attrs)
      assert json_response(invalid, 422)["error"] == "validation_error"
    end
  end

  test "clients cannot change project, business status or archive timestamps", %{
    conn: conn,
    project: project
  } do
    {:ok, requirement} = Requirements.create_requirement(project, %{title: "Draft"})

    for attrs <- [
          %{project_id: insert(:project).id},
          %{status: "completed"},
          %{archived_at: "2026-10-01T00:00:00Z"}
        ] do
      created =
        post(
          conn,
          ~p"/api/v1/projects/#{project.slug}/requirements",
          Map.put(attrs, :title, "Invalid")
        )

      assert json_response(created, 422)["error"] == "validation_error"

      updated =
        patch(conn, ~p"/api/v1/projects/#{project.slug}/requirements/#{requirement.id}", attrs)

      assert json_response(updated, 422)["error"] == "validation_error"
    end

    assert Repo.get!(Requirement, requirement.id).status == :draft
    assert Repo.get!(Requirement, requirement.id).project_id == project.id
  end

  test "another project's requirement cannot be read, edited or archived", %{
    conn: conn,
    project: project
  } do
    other = insert(:project)
    {:ok, requirement} = Requirements.create_requirement(other, %{title: "Other"})
    path = ~p"/api/v1/projects/#{project.slug}/requirements/#{requirement.id}"

    assert_error_sent 404, fn -> get(conn, path) end
    assert_error_sent 404, fn -> patch(conn, path, %{title: "Changed"}) end
    assert_error_sent 404, fn -> delete(conn, path) end
    assert Repo.get!(Requirement, requirement.id).title == "Other"
    assert Repo.get!(Requirement, requirement.id).archived_at == nil
  end

  test "archive is idempotent, retains the direct link and prevents stale edits", %{
    conn: conn,
    project: project
  } do
    {:ok, requirement} = Requirements.create_requirement(project, %{title: "Keep history"})
    path = ~p"/api/v1/projects/#{project.slug}/requirements/#{requirement.id}"
    assert response(delete(conn, path), 204) == ""
    archived_at = Repo.get!(Requirement, requirement.id).archived_at
    assert archived_at
    assert response(delete(conn, path), 204) == ""
    assert Repo.get!(Requirement, requirement.id).archived_at == archived_at

    shown = json_response(get(conn, path), 200)["data"]
    assert shown["title"] == "Keep history"
    assert shown["status"] == "draft"
    assert shown["archived_at"]

    assert {:error, _changeset} =
             Requirements.update_requirement(requirement, %{title: "Stale edit"})

    assert json_response(patch(conn, path, %{title: "Invalid"}), 422)["details"]["status"]
  end

  test "archived projects retain reads but refuse creating and editing requirements", %{
    conn: conn,
    project: project
  } do
    {:ok, requirement} = Requirements.create_requirement(project, %{title: "History"})
    {:ok, _project} = Projects.archive_project(project)
    path = ~p"/api/v1/projects/#{project.slug}/requirements/#{requirement.id}"
    assert json_response(get(conn, path), 200)["data"]["title"] == "History"
    assert json_response(patch(conn, path, %{title: "No"}), 422)["details"]["project_id"]

    created = post(conn, ~p"/api/v1/projects/#{project.slug}/requirements", %{title: "No"})
    assert json_response(created, 422)["details"]["project_id"]
  end

  test "workflow-owned non-draft status prevents metadata editing", %{project: project} do
    {:ok, requirement} = Requirements.create_requirement(project, %{title: "Draft"})
    requirement |> Ecto.Changeset.change(status: :active) |> Repo.update!()
    assert {:error, changeset} = Requirements.update_requirement(requirement, %{title: "Stale"})
    assert changeset.errors[:status]
  end

  test "unknown project or requirement returns 404", %{conn: conn, project: project} do
    assert_error_sent 404, fn -> get(conn, ~p"/api/v1/projects/missing/requirements") end
    id = UUIDv7.generate()

    assert_error_sent 404, fn ->
      get(conn, ~p"/api/v1/projects/#{project.slug}/requirements/#{id}")
    end
  end

  test "requires authentication", %{project: project} do
    conn = get(build_conn(), ~p"/api/v1/projects/#{project.slug}/requirements")
    assert json_response(conn, 401)["error"] == "unauthorized"
  end
end
