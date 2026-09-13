defmodule RintoPMOWeb.V1.DocumentControllerTest do
  use RintoPMOWeb.ConnCase, async: true

  alias RintoPMO.DocumentsMock
  alias RintoPMO.TasksMock

  test "GET /api/v1/documents lists all document summaries", %{conn: conn} do
    document = document_with_revision()

    expect(DocumentsMock, :list_documents, fn %{} = filter ->
      assert filter == %{}
      [document]
    end)

    conn = get(conn, ~p"/api/v1/documents")

    assert [data] = json_response(conn, 200)["data"]
    assert data["id"] == document.id
    assert data["status"] == "draft"
    assert data["pin"] == false
    assert data["latest_revision"]["title"] == "Plan"
    refute Map.has_key?(data["latest_revision"], "blocks")
  end

  test "GET /api/v1/documents filters by project id", %{conn: conn} do
    project = insert(:project)

    expect(DocumentsMock, :list_documents, fn %{project: project_id} ->
      assert project_id == project.id
      []
    end)

    conn = get(conn, ~p"/api/v1/documents?project_id=#{project.id}")
    assert json_response(conn, 200)["data"] == []
  end

  test "GET /api/v1/documents filters unassigned documents", %{conn: conn} do
    expect(DocumentsMock, :list_documents, fn %{project: :unassigned} -> [] end)

    conn = get(conn, ~p"/api/v1/documents?project_id=none")
    assert json_response(conn, 200)["data"] == []
  end

  test "GET /api/v1/documents filters on status, alongside the project", %{conn: conn} do
    project = insert(:project)

    expect(DocumentsMock, :list_documents, fn filter ->
      assert filter == %{project: project.id, status: :draft}
      []
    end)

    conn = get(conn, ~p"/api/v1/documents?project_id=#{project.id}&status=draft")
    assert json_response(conn, 200)["data"] == []

    expect(DocumentsMock, :list_documents, fn filter ->
      assert filter == %{status: :applied}
      []
    end)

    conn = get(conn, ~p"/api/v1/documents?status=applied")
    assert json_response(conn, 200)["data"] == []
  end

  test "GET /api/v1/documents rejects a status outside the set", %{conn: conn} do
    conn = get(conn, ~p"/api/v1/documents?status=maybe")

    assert %{
             "error" => "bad_request",
             "details" => %{"status" => ["is invalid"]}
           } = json_response(conn, 400)
  end

  test "GET /api/v1/documents rejects an invalid project id", %{conn: conn} do
    conn = get(conn, ~p"/api/v1/documents?project_id=invalid")

    assert %{
             "error" => "bad_request",
             "details" => %{"project_id" => ["is invalid"]}
           } = json_response(conn, 400)
  end

  test "GET /api/v1/documents/:id returns the latest blocks", %{conn: conn} do
    document = insert(:document)
    revision = insert(:document_revision, document: document)
    block = insert(:document_block, revision: revision)
    revision = %{revision | blocks: [block]}
    document = %{document | latest_revision: revision}

    expect(DocumentsMock, :get_document!, fn id ->
      assert id == document.id
      document
    end)

    conn = get(conn, ~p"/api/v1/documents/#{document.id}")

    assert %{"pin" => false, "latest_revision" => %{"blocks" => [rendered_block]}} =
             json_response(conn, 200)["data"]

    assert rendered_block["block_id"] == block.block_id
    refute Map.has_key?(rendered_block, "id")
  end

  test "POST /api/v1/documents creates an unassigned document", %{
    conn: conn,
    current_actor: current_actor
  } do
    document = insert(:document, project: nil)
    revision = insert(:document_revision, document: document, title: "Draft")
    revision = %{revision | blocks: []}
    document = %{document | latest_revision: revision}
    actor_id = current_actor.id

    expect(DocumentsMock, :create_document, fn %{"title" => "Draft", "actor_id" => ^actor_id} ->
      {:ok, document}
    end)

    conn = post(conn, ~p"/api/v1/documents", %{"title" => "Draft"})

    assert %{
             "project_id" => nil,
             "latest_revision" => %{"title" => "Draft", "blocks" => []}
           } = json_response(conn, 201)["data"]
  end

  test "POST /api/v1/documents passes the Markdown body through to the context", %{conn: conn} do
    document = document_with_revision()
    params = %{"title" => "Plan", "markdown" => "## One\n\ntext"}

    expect(DocumentsMock, :create_document, fn attrs ->
      assert %{"title" => "Plan", "markdown" => "## One\n\ntext"} = attrs
      {:ok, document}
    end)

    conn = post(conn, ~p"/api/v1/documents", params)

    assert json_response(conn, 201)["data"]["id"] == document.id
  end

  # The body cannot name an author: every block of a new document written
  # outside a topic is the caller's, and the token is what says who that is.
  test "POST /api/v1/documents credits the caller, not an actor in the body", %{
    conn: conn,
    current_actor: current_actor
  } do
    document = document_with_revision()
    impostor = insert(:actor)
    actor_id = current_actor.id

    expect(DocumentsMock, :create_document, fn %{"actor_id" => ^actor_id} -> {:ok, document} end)

    conn =
      post(conn, ~p"/api/v1/documents", %{
        "title" => "Plan",
        "actor_id" => impostor.id,
        "markdown" => "## One\n\ntext"
      })

    assert json_response(conn, 201)["data"]["id"] == document.id
  end

  test "POST /api/v1/documents/preview_blocks reports the split", %{conn: conn} do
    expect(DocumentsMock, :preview_blocks, fn markdown ->
      assert markdown == "## One\n\ntext\n\n## Two"
      {:ok, ["## One\n\ntext", "## Two"]}
    end)

    conn =
      post(conn, ~p"/api/v1/documents/preview_blocks", %{
        "markdown" => "## One\n\ntext\n\n## Two"
      })

    assert %{"blocks" => blocks} = json_response(conn, 200)["data"]

    assert blocks == [
             %{"position" => 0, "content" => "## One\n\ntext"},
             %{"position" => 1, "content" => "## Two"}
           ]
  end

  test "POST /api/v1/documents/preview_blocks without a body is a bad request", %{conn: conn} do
    conn = post(conn, ~p"/api/v1/documents/preview_blocks", %{})

    assert %{"error" => "bad_request", "details" => %{"markdown" => ["can't be blank"]}} =
             json_response(conn, 400)
  end

  test "POST /api/v1/documents/:id/formalize adopts a draft document", %{conn: conn} do
    document = document_with_revision()
    draft = %{document | status: :draft}
    formal = %{document | status: :formal}

    expect(DocumentsMock, :get_document!, fn id ->
      assert id == document.id
      draft
    end)

    expect(DocumentsMock, :formalize_document, fn ^draft -> {:ok, formal} end)

    conn = post(conn, ~p"/api/v1/documents/#{document.id}/formalize")

    assert json_response(conn, 200)["data"]["status"] == "formal"
  end

  test "POST /api/v1/documents/:id/pin bookmarks it at the front", %{conn: conn} do
    document = document_with_revision()
    unpinned = %{document | pin: false}
    pinned = %{document | pin: true}

    expect(DocumentsMock, :get_document!, fn id ->
      assert id == document.id
      unpinned
    end)

    expect(DocumentsMock, :pin_document, fn ^unpinned -> {:ok, pinned} end)

    conn = post(conn, ~p"/api/v1/documents/#{document.id}/pin")

    assert json_response(conn, 200)["data"]["pin"] == true
  end

  test "POST /api/v1/documents/:id/unpin clears the bookmark", %{conn: conn} do
    document = document_with_revision()
    pinned = %{document | pin: true}
    unpinned = %{document | pin: false}

    expect(DocumentsMock, :get_document!, fn id ->
      assert id == document.id
      pinned
    end)

    expect(DocumentsMock, :unpin_document, fn ^pinned -> {:ok, unpinned} end)

    conn = post(conn, ~p"/api/v1/documents/#{document.id}/unpin")

    assert json_response(conn, 200)["data"]["pin"] == false
  end

  test "POST /api/v1/documents/:id/refile moves it to the project named", %{conn: conn} do
    document = document_with_revision()
    project = insert(:project)
    moved = %{document | project_id: project.id}

    expect(DocumentsMock, :get_document!, fn id ->
      assert id == document.id
      document
    end)

    expect(DocumentsMock, :refile_document, fn ^document, project_id ->
      assert project_id == project.id
      {:ok, moved}
    end)

    conn = post(conn, ~p"/api/v1/documents/#{document.id}/refile", %{project_id: project.id})

    assert json_response(conn, 200)["data"]["project_id"] == project.id
  end

  # Not defaulted to anything, and refused before the document is even read.
  # Filing a document nowhere is what creation reaches for the default project
  # to avoid, and doing it here by omission would undo that quietly.
  test "POST /api/v1/documents/:id/refile without a project is a bad request", %{conn: conn} do
    document = document_with_revision()

    conn = post(conn, ~p"/api/v1/documents/#{document.id}/refile", %{})

    assert %{"error" => "bad_request", "details" => %{"project_id" => ["can't be blank"]}} =
             json_response(conn, 400)
  end

  test "DELETE /api/v1/documents/:id archives idempotently", %{conn: conn} do
    document = document_with_revision()
    archived = %{document | archived_at: DateTime.utc_now()}

    expect(DocumentsMock, :get_document!, fn id ->
      assert id == document.id
      document
    end)

    expect(DocumentsMock, :archive_document, fn ^document -> {:ok, archived} end)

    conn = delete(conn, ~p"/api/v1/documents/#{document.id}")

    assert response(conn, 204) == ""
  end

  # 201 and every task created, flat with `parent_id` on each -- the same shape
  # the project's task list gives, so a client builds the tree the way it does.
  test "POST /api/v1/documents/:id/file_breakdown answers with what it made", %{conn: conn} do
    document = document_with_revision()
    summary = insert(:task, kind: :summary, title: "灰度发布")
    child = insert(:task, title: "接入十分之一流量", parent_id: summary.id)

    expect(DocumentsMock, :get_document!, fn _id -> document end)
    expect(TasksMock, :file_breakdown, fn ^document -> {:ok, [summary, child]} end)

    conn = post(conn, ~p"/api/v1/documents/#{document.id}/file_breakdown")

    assert [first, second] = json_response(conn, 201)["data"]
    assert first["title"] == "灰度发布"
    assert first["kind"] == "summary"
    assert second["parent_id"] == summary.id
  end

  test "POST /api/v1/documents/:id/file_breakdown relays a refusal", %{conn: conn} do
    document = document_with_revision()

    expect(DocumentsMock, :get_document!, fn _id -> document end)

    expect(TasksMock, :file_breakdown, fn ^document ->
      {:error, :document_not_formal, %{status: :applied}}
    end)

    conn = post(conn, ~p"/api/v1/documents/#{document.id}/file_breakdown")

    assert %{"error" => "document_not_formal"} = json_response(conn, 422)
  end

  # The rest of this file mocks the context to test the controller alone. These
  # two run the real one, because importing a document is the one flow where
  # the wiring is the feature: a body posted as one string has to come back as
  # the blocks the server decided to cut it into.
  describe "importing a Markdown body end to end" do
    setup do
      stub_with(DocumentsMock, RintoPMO.Documents)
      # A document posted without a project is filed in the default one, which
      # therefore has to exist.
      stub_with(RintoPMO.ProjectsMock, RintoPMO.Projects)
      insert(:default_project)
      :ok
    end

    test "POST /api/v1/documents cuts the body into blocks", %{
      conn: conn,
      current_actor: actor
    } do
      conn =
        post(conn, ~p"/api/v1/documents", %{
          "title" => "Plan",
          "markdown" => "preamble\n\n## Background\n\nContext\n\n### Detail\n\nMore"
        })

      assert %{"latest_revision" => %{"title" => "Plan", "blocks" => blocks}} =
               json_response(conn, 201)["data"]

      assert Enum.map(blocks, & &1["content"]) == [
               "preamble",
               "## Background\n\nContext",
               "### Detail\n\nMore"
             ]

      assert Enum.map(blocks, & &1["position"]) == [0, 1, 2]
      assert Enum.all?(blocks, &(&1["actor_id"] == actor.id))
    end

    test "POST /api/v1/documents/preview_blocks agrees with what create would do", %{conn: conn} do
      markdown = "# One\n\nfirst\n\n## Two\n\nsecond"
      actor = insert(:actor)

      preview =
        conn
        |> post(~p"/api/v1/documents/preview_blocks", %{"markdown" => markdown})
        |> json_response(200)

      created =
        conn
        |> post(~p"/api/v1/documents", %{
          "title" => "Plan",
          "actor_id" => actor.id,
          "markdown" => markdown
        })
        |> json_response(201)

      assert Enum.map(preview["data"]["blocks"], & &1["content"]) ==
               Enum.map(created["data"]["latest_revision"]["blocks"], & &1["content"])
    end
  end

  defp document_with_revision do
    document = insert(:document)
    revision = insert(:document_revision, document: document, title: "Plan")
    %{document | latest_revision: %{revision | blocks: []}}
  end
end
