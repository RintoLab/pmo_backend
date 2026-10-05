defmodule RintoPMOWeb.V1.DocumentClassificationTest do
  use RintoPMOWeb.ConnCase, async: true

  alias RintoPMO.Documents
  alias RintoPMO.DocumentsMock
  alias RintoPMO.Projects
  alias RintoPMO.ProjectsMock
  alias RintoPMO.Requirements

  setup do
    stub_with(DocumentsMock, Documents)
    stub_with(ProjectsMock, Projects)
    insert(:default_project)
    project = insert(:project)
    {:ok, requirement} = Requirements.create_requirement(project, %{title: "Login"})
    %{project: project, requirement: requirement}
  end

  test "existing creation defaults to general and never guesses from the title", %{conn: conn} do
    created = post(conn, ~p"/api/v1/documents", %{title: "RFC: Login spec"})
    data = json_response(created, 201)["data"]
    assert data["kind"] == "general"
    assert data["requirement_id"] == nil
    assert data["status"] == "draft"
    assert data["project_id"] == Projects.get_default_project().id
  end

  test "five kinds are independent of scope and status", %{conn: conn} do
    for kind <- ~w(general rfc spec plan task) do
      data = conn |> post(~p"/api/v1/documents", %{title: kind, kind: kind}) |> json_response(201)
      assert data["data"]["kind"] == kind
      assert data["data"]["requirement_id"] == nil
      assert data["data"]["status"] == "draft"
    end

    for kind <- ["prd", "research", "tasks", "unknown", nil] do
      response =
        conn |> post(~p"/api/v1/documents", %{title: "Invalid", kind: kind}) |> json_response(422)

      assert response["details"]["kind"]
    end
  end

  test "requirement creation derives project and rejects invalid ownership", %{
    conn: conn,
    project: project,
    requirement: requirement
  } do
    data =
      conn
      |> post(~p"/api/v1/documents", %{
        title: "Spec",
        kind: "spec",
        requirement_id: requirement.id
      })
      |> json_response(201)

    assert data["data"]["project_id"] == project.id
    assert data["data"]["requirement_id"] == requirement.id

    for id <- ["not-a-uuid", UUIDv7.generate()] do
      response =
        conn
        |> post(~p"/api/v1/documents", %{title: "Invalid", requirement_id: id})
        |> json_response(422)

      assert response["details"]["requirement_id"]
    end

    foreign_project = insert(:project)

    response =
      conn
      |> post(~p"/api/v1/documents", %{
        title: "Wrong project",
        project_id: foreign_project.id,
        requirement_id: requirement.id
      })
      |> json_response(422)

    assert response["details"]["requirement_id"]
    {:ok, _} = Requirements.archive_requirement(requirement)

    response =
      conn
      |> post(~p"/api/v1/documents", %{title: "Archived", requirement_id: requirement.id})
      |> json_response(422)

    assert response["details"]["requirement_id"]
  end

  test "list defaults to independent documents, even for pins, and supports explicit scope and kind",
       %{conn: conn, project: project, requirement: requirement} do
    {:ok, public} =
      Documents.create_document(%{title: "RFC", kind: "rfc", project_id: project.id})

    {:ok, spec} =
      Documents.create_document(%{title: "Spec", kind: "spec", requirement_id: requirement.id})

    {:ok, _} = Documents.pin_document(spec)

    {:ok, child} =
      Requirements.create_requirement(project, %{title: "Child", parent_id: requirement.id})

    {:ok, child_doc} =
      Documents.create_document(%{title: "Child spec", kind: "spec", requirement_id: child.id})

    assert ids(get(conn, ~p"/api/v1/documents")) == [public.id]
    assert ids(get(conn, ~p"/api/v1/documents?requirement_id=none")) == [public.id]
    assert ids(get(conn, ~p"/api/v1/documents?requirement_id=#{requirement.id}")) == [spec.id]

    assert Enum.sort(ids(get(conn, ~p"/api/v1/documents?requirement_id=all&kind=spec"))) ==
             Enum.sort([spec.id, child_doc.id])

    assert ids(get(conn, ~p"/api/v1/documents?requirement_id=#{requirement.id}&kind=plan")) == []

    assert ids(
             get(conn, ~p"/api/v1/documents?requirement_id=all&project_id=#{UUIDv7.generate()}")
           ) == []

    {:ok, _} = Documents.archive_document(spec)
    assert ids(get(conn, ~p"/api/v1/documents?requirement_id=#{requirement.id}")) == []

    assert json_response(get(conn, ~p"/api/v1/documents/#{spec.id}"), 200)["data"][
             "requirement_id"
           ] == requirement.id
  end

  test "metadata edits retain content, revision, pin and adoption; null explicitly unlinks", %{
    conn: conn,
    project: project,
    requirement: requirement,
    current_actor: actor
  } do
    {:ok, document} =
      Documents.create_document(%{
        title: "A note",
        project_id: project.id,
        actor_id: actor.id,
        markdown: "## Scope\n\nKeep this content"
      })

    {:ok, document} = Documents.formalize_document(document)
    {:ok, document} = Documents.pin_document(document)
    before = json_response(get(conn, ~p"/api/v1/documents/#{document.id}"), 200)["data"]

    updated =
      conn
      |> patch(~p"/api/v1/documents/#{document.id}", %{
        kind: "spec",
        requirement_id: requirement.id
      })
      |> json_response(200)

    assert updated["data"]["latest_revision"] == before["latest_revision"]
    assert updated["data"]["status"] == "formal"
    assert updated["data"]["pin"] == true
    assert updated["data"]["requirement_id"] == requirement.id
    assert ids(get(conn, ~p"/api/v1/documents")) == []

    kind_only =
      conn |> patch(~p"/api/v1/documents/#{document.id}", %{kind: "rfc"}) |> json_response(200)

    assert kind_only["data"]["requirement_id"] == requirement.id

    unlinked =
      conn
      |> patch(~p"/api/v1/documents/#{document.id}", %{requirement_id: nil})
      |> json_response(200)

    assert unlinked["data"]["requirement_id"] == nil
    assert unlinked["data"]["kind"] == "rfc"
    assert ids(get(conn, ~p"/api/v1/documents")) == [document.id]
    assert length(Documents.list_revisions(document)) == 1
  end

  test "metadata and refile cannot break ownership or modify archived documents", %{
    conn: conn,
    project: project,
    requirement: requirement
  } do
    other_project = insert(:project)
    {:ok, other} = Requirements.create_requirement(other_project, %{title: "Elsewhere"})

    {:ok, document} =
      Documents.create_document(%{title: "Spec", kind: "spec", requirement_id: requirement.id})

    response =
      conn
      |> patch(~p"/api/v1/documents/#{document.id}", %{requirement_id: other.id})
      |> json_response(422)

    assert response["details"]["requirement_id"]
    assert {:error, _} = Documents.refile_document(document, other_project.id)
    assert Documents.get_document!(document.id).project_id == project.id
    {:ok, _} = Documents.archive_document(document)

    response =
      conn
      |> patch(~p"/api/v1/documents/#{document.id}", %{kind: "plan", requirement_id: nil})
      |> json_response(422)

    assert response["details"]["archived_at"]
    assert Documents.get_document!(document.id).kind == :spec
  end

  test "invalid list filters are reported, not ignored", %{conn: conn} do
    for params <- [%{kind: "prd"}, %{requirement_id: ""}, %{requirement_id: "bad"}] do
      assert json_response(get(conn, ~p"/api/v1/documents", params), 400)["error"] ==
               "bad_request"
    end
  end

  defp ids(conn), do: conn |> json_response(200) |> Map.fetch!("data") |> Enum.map(& &1["id"])
end
