defmodule RintoPMOWeb.V1.RequirementControllerTest do
  use RintoPMOWeb.ConnCase, async: true

  alias RintoPMO.Documents
  alias RintoPMO.Projects
  alias RintoPMO.Repo
  alias RintoPMO.Requirements
  alias RintoPMO.Requirements.Requirement
  alias RintoPMO.Requirements.Tree

  setup do
    project = insert(:project)
    {:ok, project: project}
  end

  test "both list endpoints sort on the server with stable ties and parent filtering", %{
    conn: conn,
    project: project
  } do
    old = ~U[2026-01-01 00:00:00.000000Z]
    recent = ~U[2026-02-01 00:00:00.000000Z]
    latest = ~U[2026-03-01 00:00:00.000000Z]
    a = insert(:requirement, project: project, priority: 1, inserted_at: old, updated_at: latest)

    b =
      insert(:requirement, project: project, priority: 5, inserted_at: recent, updated_at: recent)

    c =
      insert(:requirement, project: project, priority: 1, inserted_at: recent, updated_at: recent)

    d =
      insert(:requirement, project: project, priority: 1, inserted_at: recent, updated_at: recent)

    ties = Enum.sort([c.id, d.id], :desc)
    created = Enum.sort([b.id, c.id, d.id], :desc) ++ [a.id]
    insert(:requirement, project: project, archived_at: latest, priority: 1)
    child = insert(:requirement, project: project, parent_id: a.id, priority: 2)

    for path <- [~p"/api/v1/requirements", ~p"/api/v1/projects/#{project.slug}/requirements"] do
      for {sort, expected} <- [
            {"created", created},
            {"updated", [a.id | Enum.sort([b.id, c.id, d.id], :desc)]},
            {"priority", ties ++ [a.id, b.id]}
          ] do
        response = conn |> get(path, %{sort: sort}) |> json_response(200)
        assert Enum.map(response["data"], & &1["id"]) == expected
      end

      response = conn |> get(path) |> json_response(200)
      assert Enum.map(response["data"], & &1["id"]) == created
      response = conn |> get(path, %{sort: "priority", parent_id: "all"}) |> json_response(200)
      assert Enum.map(response["data"], & &1["id"]) == ties ++ [a.id, child.id, b.id]
      response = conn |> get(path, %{sort: "updated", parent_id: a.id}) |> json_response(200)
      assert Enum.map(response["data"], & &1["id"]) == [child.id]
    end
  end

  test "both list endpoints reject unsupported sort values", %{conn: conn, project: project} do
    for path <- [~p"/api/v1/requirements", ~p"/api/v1/projects/#{project.slug}/requirements"],
        sort <- ["", "title", "priority desc", ["priority"]] do
      response = conn |> get(path, %{sort: sort}) |> json_response(400)
      assert response["details"]["sort"] == ["is invalid"]
    end
  end

  test "priority is returned by all reads and can be changed on active requirements", %{
    conn: conn,
    project: project
  } do
    requirement = insert(:requirement, project: project, status: :active, priority: 4)

    updated =
      conn
      |> patch(~p"/api/v1/requirements/#{requirement.id}", %{priority: 1})
      |> json_response(200)

    assert updated["data"]["priority"] == 1
    assert updated["data"]["status"] == "active"
    shown = conn |> get(~p"/api/v1/requirements/#{requirement.id}") |> json_response(200)
    assert shown["data"]["priority"] == 1
    listed = conn |> get(~p"/api/v1/projects/#{project.slug}/requirements") |> json_response(200)
    assert hd(listed["data"])["priority"] == 1

    invalid =
      conn
      |> patch(~p"/api/v1/requirements/#{requirement.id}", %{priority: 6})
      |> json_response(422)

    assert invalid["details"]["priority"]
  end

  test "flat endpoints create roots and children, browse by parent and edit by id", %{
    conn: conn,
    project: project
  } do
    root =
      conn
      |> post(~p"/api/v1/requirements", %{project_slug: project.slug, title: "Account"})
      |> json_response(201)
      |> Map.fetch!("data")

    assert root["project"]["slug"] == project.slug
    assert root["documents"] == []
    assert root["parent_id"] == nil

    child =
      conn
      |> post(~p"/api/v1/requirements", %{
        parent_id: root["id"],
        title: "SMS",
        description: "## Goal\n\nPreserve Markdown"
      })
      |> json_response(201)
      |> Map.fetch!("data")

    assert child["project_id"] == project.id
    assert child["parent_id"] == root["id"]
    shown = conn |> get(~p"/api/v1/requirements/#{root["id"]}") |> json_response(200)
    assert shown["data"]["child_count"] == 1

    children =
      conn |> get(~p"/api/v1/requirements?parent_id=#{root["id"]}") |> json_response(200)

    assert Enum.map(children["data"], & &1["id"]) == [child["id"]]
    assert hd(children["data"])["project"]["slug"] == project.slug
    refute Map.has_key?(hd(children["data"]), "documents")
    all = conn |> get(~p"/api/v1/requirements?parent_id=all") |> json_response(200)
    assert length(all["data"]) == 2

    path = ~p"/api/v1/requirements/#{child["id"]}"
    updated = conn |> patch(path, %{title: "New title"}) |> json_response(200)
    assert updated["data"]["description"] == child["description"]
    cleared = conn |> patch(path, %{description: ""}) |> json_response(200)
    assert cleared["data"]["title"] == "New title"
    assert cleared["data"]["description"] == ""
    assert cleared["data"]["documents"] == []
  end

  test "flat creation requires one scope and preserves project, parent and draft guards", %{
    conn: conn,
    project: project
  } do
    {:ok, parent} = Requirements.create_requirement(project, %{title: "Parent"})

    for scope <- [
          %{},
          %{project_slug: ""},
          %{project_slug: project.slug, parent_id: parent.id},
          %{project_slug: nil, parent_id: parent.id},
          %{parent_id: "invalid"}
        ] do
      assert json_response(
               post(conn, ~p"/api/v1/requirements", Map.put(scope, :title, "No")),
               400
             )
    end

    path = ~p"/api/v1/requirements/#{parent.id}"

    for attrs <- [%{project_id: project.id}, %{parent_id: nil}] do
      assert json_response(patch(conn, path, attrs), 422)["error"] == "validation_error"
    end

    response =
      post(conn, ~p"/api/v1/requirements", %{
        parent_id: parent.id,
        project_id: insert(:project).id,
        title: "Wrong project"
      })

    assert json_response(response, 422)["details"]["project_id"]

    parent |> Ecto.Changeset.change(status: :completed) |> Repo.update!()
    assert json_response(patch(conn, path, %{title: "No"}), 422)["details"]["status"]
    response = post(conn, ~p"/api/v1/requirements", %{parent_id: parent.id, title: "No"})
    assert json_response(response, 422)["details"]["parent_id"]

    {:ok, archived} = Requirements.create_requirement(project, %{title: "Archived"})
    {:ok, _} = Requirements.archive_requirement(archived)
    response = post(conn, ~p"/api/v1/requirements", %{parent_id: archived.id, title: "No"})
    assert json_response(response, 422)["details"]["parent_id"]

    {:ok, open} = Requirements.create_requirement(project, %{title: "Open"})
    {:ok, _} = Projects.archive_project(project)

    assert json_response(get(conn, ~p"/api/v1/requirements/#{open.id}"), 200)["data"]["project"][
             "status"
           ] == "archived"

    assert json_response(patch(conn, ~p"/api/v1/requirements/#{open.id}", %{title: "No"}), 422)[
             "details"
           ]["project_id"]

    for scope <- [%{project_slug: project.slug}, %{parent_id: open.id}] do
      assert json_response(
               post(conn, ~p"/api/v1/requirements", Map.put(scope, :title, "No")),
               422
             )["details"]["project_id"]
    end
  end

  test "flat routes report missing ids and require authentication", %{conn: conn} do
    id = UUIDv7.generate()

    for action <- [
          fn -> get(conn, ~p"/api/v1/requirements/#{id}") end,
          fn -> patch(conn, ~p"/api/v1/requirements/#{id}", %{title: "No"}) end,
          fn -> post(conn, ~p"/api/v1/requirements", %{parent_id: id, title: "No"}) end,
          fn -> get(conn, ~p"/api/v1/requirements?parent_id=#{id}") end
        ] do
      assert_error_sent 404, action
    end

    assert json_response(get(conn, ~p"/api/v1/requirements/invalid"), 400)["details"]["id"]

    assert json_response(get(conn, ~p"/api/v1/requirements?parent_id=invalid"), 400)["details"][
             "parent_id"
           ]

    assert json_response(get(build_conn(), ~p"/api/v1/requirements/#{id}"), 401)

    assert json_response(
             post(build_conn(), ~p"/api/v1/requirements", %{parent_id: id, title: "No"}),
             401
           )

    assert json_response(patch(build_conn(), ~p"/api/v1/requirements/#{id}", %{title: "No"}), 401)
  end

  test "detail includes every direct document summary, without bodies, descendants or archives",
       %{
         conn: conn,
         project: project,
         current_actor: actor
       } do
    stub_with(RintoPMO.DocumentsMock, Documents)
    {:ok, root} = Requirements.create_requirement(project, %{title: "Root"})
    {:ok, child} = Requirements.create_requirement(project, %{title: "Child", parent_id: root.id})
    {:ok, sibling} = Requirements.create_requirement(project, %{title: "Sibling"})

    documents =
      for kind <- ~w(general rfc spec plan task spec) do
        {:ok, document} =
          Documents.create_document(%{
            requirement_id: root.id,
            kind: kind,
            title: "Title #{kind}",
            actor_id: actor.id,
            markdown: "## Body\n\nRead separately"
          })

        document
      end

    for requirement <- [child, sibling] do
      {:ok, _} = Documents.create_document(%{requirement_id: requirement.id, title: "Other"})
    end

    {:ok, hidden} = Documents.create_document(%{requirement_id: root.id, title: "Archived"})
    {:ok, _} = Documents.archive_document(hidden)

    shown =
      conn |> get(~p"/api/v1/requirements/#{root.id}") |> json_response(200) |> Map.fetch!("data")

    scoped =
      conn
      |> get(~p"/api/v1/projects/#{project.slug}/requirements/#{root.id}")
      |> json_response(200)

    assert scoped["data"] == shown
    assert Enum.map(shown["documents"], & &1["id"]) == Enum.reverse(Enum.map(documents, & &1.id))

    assert Enum.all?(shown["documents"], fn document ->
             document["requirement_id"] == root.id && document["status"] == "draft" &&
               String.starts_with?(document["latest_revision"]["title"], "Title ") &&
               not Map.has_key?(document["latest_revision"], "blocks")
           end)

    document = hd(documents)
    body = conn |> get(~p"/api/v1/documents/#{document.id}") |> json_response(200)
    assert hd(body["data"]["latest_revision"]["blocks"])["content"] =~ "Read separately"
    listed = conn |> get(~p"/api/v1/requirements") |> json_response(200)
    assert Enum.all?(listed["data"], &(not Map.has_key?(&1, "documents")))
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

  test "global overview lists roots across projects with child counts and keeps archives hidden",
       %{
         conn: conn,
         project: project
       } do
    other_project = insert(:project)
    {:ok, first} = Requirements.create_requirement(project, %{title: "First project"})

    {:ok, child} =
      Requirements.create_requirement(project, %{title: "Child", parent_id: first.id})

    {:ok, hidden_child} =
      Requirements.create_requirement(project, %{title: "Archived child", parent_id: first.id})

    {:ok, _} = Requirements.archive_requirement(hidden_child)
    {:ok, hidden} = Requirements.create_requirement(project, %{title: "Archived root"})
    {:ok, _} = Requirements.archive_requirement(hidden)
    {:ok, second} = Requirements.create_requirement(other_project, %{title: "Second project"})
    {:ok, _} = Projects.archive_project(other_project)

    data = conn |> get(~p"/api/v1/requirements") |> json_response(200) |> Map.fetch!("data")
    assert Enum.map(data, & &1["id"]) == [second.id, first.id]
    assert Enum.map(data, & &1["project_id"]) == [other_project.id, project.id]
    assert Enum.map(data, & &1["project"]["slug"]) == [other_project.slug, project.slug]
    assert Enum.map(data, & &1["project"]["status"]) == ["archived", "active"]
    assert hd(data)["project"]["name"] == other_project.name
    assert Enum.map(data, & &1["child_count"]) == [0, 1]
    assert Enum.all?(data, &is_nil(&1["parent_id"]))

    children =
      conn
      |> get(~p"/api/v1/projects/#{project.slug}/requirements?parent_id=#{first.id}")
      |> json_response(200)

    assert Enum.map(children["data"], & &1["id"]) == [child.id]
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

  test "progress markers are reversible without document, task or child gates", %{
    conn: conn,
    project: project
  } do
    parent = insert(:requirement, project: project)
    child = insert(:requirement, project: project, parent: parent)
    task = insert(:task, project: project, requirement: child)

    for status <- ["analyzed", "active", "completed", "analyzed", "draft"],
        requirement <- [parent, child] do
      result = patch(conn, ~p"/api/v1/requirements/#{requirement.id}", %{status: status})
      assert json_response(result, 200)["data"]["status"] == status
      assert Repo.get!(RintoPMO.Tasks.Task, task.id).status == :open
    end

    for status <- [nil, "paused", "cancelled"] do
      assert conn
             |> patch(~p"/api/v1/requirements/#{child.id}", %{status: status})
             |> json_response(422)
    end

    assert conn
           |> post(~p"/api/v1/projects/#{project.slug}/requirements", %{
             title: "No",
             status: "active"
           })
           |> json_response(422)

    {:ok, _} = Requirements.archive_requirement(child)

    assert conn
           |> patch(~p"/api/v1/requirements/#{child.id}", %{status: "active"})
           |> json_response(422)
  end

  test "analyzed is persisted through scoped updates and remains open for children", %{
    conn: conn,
    project: project
  } do
    parent = insert(:requirement, project: project)
    path = ~p"/api/v1/projects/#{project.slug}/requirements/#{parent.id}"

    assert json_response(put(conn, path, %{status: "analyzed"}), 200)["data"]["status"] ==
             "analyzed"

    assert json_response(get(conn, path), 200)["data"]["status"] == "analyzed"
    listed = json_response(get(conn, ~p"/api/v1/requirements"), 200)["data"]
    assert Enum.find(listed, &(&1["id"] == parent.id))["status"] == "analyzed"

    child = post(conn, ~p"/api/v1/requirements", %{parent_id: parent.id, title: "Child"})
    child_id = json_response(child, 201)["data"]["id"]
    tree = Tree.load([project.id])
    assert Tree.open?(Requirements.get_requirement!(parent.id))

    assert Tree.descendants(tree, [parent.id], true) ==
             Enum.sort([parent.id, child_id])

    {:ok, _} = Requirements.archive_requirement(Requirements.get_requirement!(child_id))
    {:ok, archived} = Requirements.archive_requirement(Requirements.get_requirement!(parent.id))
    refute Tree.open?(archived)
    assert json_response(patch(conn, path, %{status: "analyzed"}), 422)
  end

  test "clients cannot change project or archive timestamps", %{
    conn: conn,
    project: project
  } do
    {:ok, requirement} = Requirements.create_requirement(project, %{title: "Draft"})

    for attrs <- [
          %{project_id: insert(:project).id},
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

  test "creates nested requirements and lists one level at a time", %{
    conn: conn,
    project: project
  } do
    base = ~p"/api/v1/projects/#{project.slug}/requirements"
    root = json_response(post(conn, base, %{title: "Account system"}), 201)["data"]
    assert root["parent_id"] == nil
    assert root["child_count"] == 0

    child =
      json_response(post(conn, base, %{title: "SMS login", parent_id: root["id"]}), 201)["data"]

    grandchild =
      json_response(post(conn, base, %{title: "Verification rules", parent_id: child["id"]}), 201)[
        "data"
      ]

    assert child["parent_id"] == root["id"]
    assert grandchild["parent_id"] == child["id"]
    assert child["project_id"] == project.id

    assert Enum.map(json_response(get(conn, base), 200)["data"], & &1["id"]) == [root["id"]]
    children = json_response(get(conn, base, %{parent_id: root["id"]}), 200)["data"]
    assert Enum.map(children, & &1["id"]) == [child["id"]]
    assert hd(children)["child_count"] == 1
    assert length(json_response(get(conn, base, %{parent_id: "all"}), 200)["data"]) == 3
    assert length(json_response(get(conn, base, %{parent_id: "none"}), 200)["data"]) == 1
    assert json_response(get(conn, base <> "/" <> root["id"]), 200)["data"]["child_count"] == 1

    assert json_response(patch(conn, base <> "/" <> root["id"], %{description: "Revised"}), 200)[
             "data"
           ]["child_count"] == 1
  end

  test "rejects invalid, missing and cross-project parents", %{conn: conn, project: project} do
    {:ok, other} = Requirements.create_requirement(insert(:project), %{title: "Other"})
    base = ~p"/api/v1/projects/#{project.slug}/requirements"

    for parent_id <- ["", "invalid", UUIDv7.generate(), other.id] do
      response = post(conn, base, %{title: "Invalid child", parent_id: parent_id})
      assert json_response(response, 422)["details"]["parent_id"]
    end

    assert Requirements.list_requirements(project, :all) == []
    assert json_response(get(conn, base, %{parent_id: "invalid"}), 400)["details"]["parent_id"]
    assert_error_sent 404, fn -> get(conn, base, %{parent_id: other.id}) end
    assert_error_sent 404, fn -> get(conn, base, %{parent_id: UUIDv7.generate()}) end
  end

  test "parent ownership cannot be changed or cleared through metadata updates", %{
    conn: conn,
    project: project
  } do
    {:ok, root} = Requirements.create_requirement(project, %{title: "Root"})
    {:ok, child} = Requirements.create_requirement(project, %{title: "Child", parent_id: root.id})

    for {target, parent_id} <- [{root, root.id}, {root, child.id}, {child, nil}] do
      path = ~p"/api/v1/projects/#{project.slug}/requirements/#{target.id}"

      assert json_response(patch(conn, path, %{parent_id: parent_id}), 422)["details"][
               "parent_id"
             ]

      assert json_response(put(conn, path, %{parent_id: parent_id}), 422)["details"]["parent_id"]
    end

    assert Repo.get!(Requirement, root.id).parent_id == nil
    assert Repo.get!(Requirement, child.id).parent_id == root.id
  end

  test "archiving never hides an unarchived subtree", %{conn: conn, project: project} do
    {:ok, root} = Requirements.create_requirement(project, %{title: "Root"})
    {:ok, child} = Requirements.create_requirement(project, %{title: "Child", parent_id: root.id})

    {:ok, grandchild} =
      Requirements.create_requirement(project, %{title: "Grandchild", parent_id: child.id})

    base = ~p"/api/v1/projects/#{project.slug}/requirements"

    for requirement <- [root, child] do
      assert json_response(delete(conn, base <> "/" <> requirement.id), 422)["details"][
               "children"
             ]

      assert Repo.get!(Requirement, requirement.id).archived_at == nil
    end

    for requirement <- [grandchild, child, root] do
      assert response(delete(conn, base <> "/" <> requirement.id), 204) == ""
      shown = json_response(get(conn, base <> "/" <> requirement.id), 200)["data"]
      assert shown["parent_id"] == requirement.parent_id
      assert shown["child_count"] == 0
      assert shown["archived_at"]
    end
  end

  test "an archived or closed parent cannot receive new children", %{project: project} do
    for status <- [:completed, :cancelled] do
      {:ok, parent} = Requirements.create_requirement(project, %{title: "Parent"})
      parent |> Ecto.Changeset.change(status: status) |> Repo.update!()

      assert {:error, changeset} =
               Requirements.create_requirement(project, %{title: "Child", parent_id: parent.id})

      assert changeset.errors[:parent_id]
    end

    {:ok, parent} = Requirements.create_requirement(project, %{title: "Parent"})
    {:ok, _archived} = Requirements.archive_requirement(parent)

    assert {:error, changeset} =
             Requirements.create_requirement(project, %{title: "Child", parent_id: parent.id})

    assert changeset.errors[:parent_id]
  end

  test "an active parent can receive children and stale project data cannot bypass archive", %{
    project: project
  } do
    {:ok, parent} = Requirements.create_requirement(project, %{title: "Parent"})
    parent |> Ecto.Changeset.change(status: :active) |> Repo.update!()

    assert {:ok, _child} =
             Requirements.create_requirement(project, %{title: "Child", parent_id: parent.id})

    {:ok, _archived} = Projects.archive_project(project)

    assert {:error, changeset} =
             Requirements.create_requirement(project, %{title: "No", parent_id: parent.id})

    assert changeset.errors[:project_id]
  end
end
