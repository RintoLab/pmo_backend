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

    assert %{"latest_revision" => %{"blocks" => [rendered_block]}} =
             json_response(conn, 200)["data"]

    assert rendered_block["block_id"] == block.block_id
    refute Map.has_key?(rendered_block, "id")
  end

  test "POST /api/v1/documents creates an unassigned document", %{conn: conn} do
    document = insert(:document, project: nil)
    revision = insert(:document_revision, document: document, title: "Draft")
    revision = %{revision | blocks: []}
    document = %{document | latest_revision: revision}
    params = %{"title" => "Draft"}

    expect(DocumentsMock, :create_document, fn ^params -> {:ok, document} end)

    conn = post(conn, ~p"/api/v1/documents", params)

    assert %{
             "project_id" => nil,
             "latest_revision" => %{"title" => "Draft", "blocks" => []}
           } = json_response(conn, 201)["data"]
  end

  test "POST /api/v1/documents passes the Markdown body through to the context", %{conn: conn} do
    document = document_with_revision()
    params = %{"title" => "Plan", "actor_id" => document.id, "markdown" => "## One\n\ntext"}

    expect(DocumentsMock, :create_document, fn ^params -> {:ok, document} end)

    conn = post(conn, ~p"/api/v1/documents", params)

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

  # 202 and the attempt, not 200 and the breakdown: the model call runs in a
  # job, and what a client does next is watch `document:{id}` on the socket.
  test "POST /api/v1/documents/:id/decompose answers with the queued attempt", %{conn: conn} do
    document = document_with_revision()
    attempt = decomposition(document)

    expect(DocumentsMock, :get_document!, fn _id -> document end)
    expect(DocumentsMock, :request_decomposition, fn ^document -> {:ok, attempt} end)

    conn = post(conn, ~p"/api/v1/documents/#{document.id}/decompose")

    assert %{"id" => id, "status" => "pending", "result_document_id" => nil} =
             json_response(conn, 202)["data"]

    assert id == attempt.id
  end

  # Told no while they are still looking at the button.
  test "POST /api/v1/documents/:id/decompose relays a refusal", %{conn: conn} do
    document = document_with_revision()

    expect(DocumentsMock, :get_document!, fn _id -> document end)

    expect(DocumentsMock, :request_decomposition, fn ^document ->
      {:error, :document_not_formal, %{status: :draft}}
    end)

    conn = post(conn, ~p"/api/v1/documents/#{document.id}/decompose")

    assert %{"error" => "document_not_formal"} = json_response(conn, 422)
  end

  test "GET /api/v1/documents/:id/decomposition answers null when there was none", %{conn: conn} do
    document = document_with_revision()

    expect(DocumentsMock, :get_document!, fn _id -> document end)
    expect(DocumentsMock, :latest_decomposition, fn ^document -> nil end)

    conn = get(conn, ~p"/api/v1/documents/#{document.id}/decomposition")

    assert json_response(conn, 200)["data"] == nil
  end

  test "GET /api/v1/documents/:id/decomposition carries the failure reason", %{conn: conn} do
    document = document_with_revision()
    attempt = %{decomposition(document) | status: :failed, error: "decomposition_failed: timeout"}

    expect(DocumentsMock, :get_document!, fn _id -> document end)
    expect(DocumentsMock, :latest_decomposition, fn ^document -> attempt end)

    conn = get(conn, ~p"/api/v1/documents/#{document.id}/decomposition")

    assert %{"status" => "failed", "error" => "decomposition_failed: timeout"} =
             json_response(conn, 200)["data"]
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

    test "POST /api/v1/documents cuts the body into blocks", %{conn: conn} do
      actor = insert(:actor)

      conn =
        post(conn, ~p"/api/v1/documents", %{
          "title" => "Plan",
          "actor_id" => actor.id,
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

  # Built rather than inserted: these tests are about what the controller does
  # with what the context hands it.
  defp decomposition(document) do
    build(:document_decomposition,
      id: UUIDv7.generate(),
      source_document: nil,
      source_document_id: document.id,
      inserted_at: DateTime.utc_now(),
      updated_at: DateTime.utc_now()
    )
  end
end
