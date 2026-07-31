defmodule RintoPMOWeb.V1.DocumentControllerTest do
  use RintoPMOWeb.ConnCase, async: true

  alias RintoPMO.DocumentsMock

  test "GET /api/v1/documents lists all document summaries", %{conn: conn} do
    document = document_with_revision()

    expect(DocumentsMock, :list_documents, fn :all -> [document] end)

    conn = get(conn, ~p"/api/v1/documents")

    assert [data] = json_response(conn, 200)["data"]
    assert data["id"] == document.id
    assert data["latest_revision"]["title"] == "Plan"
    refute Map.has_key?(data["latest_revision"], "blocks")
  end

  test "GET /api/v1/documents filters by project id", %{conn: conn} do
    project = insert(:project)

    expect(DocumentsMock, :list_documents, fn {:project, project_id} ->
      assert project_id == project.id
      []
    end)

    conn = get(conn, ~p"/api/v1/documents?project_id=#{project.id}")
    assert json_response(conn, 200)["data"] == []
  end

  test "GET /api/v1/documents filters unassigned documents", %{conn: conn} do
    expect(DocumentsMock, :list_documents, fn :unassigned -> [] end)

    conn = get(conn, ~p"/api/v1/documents?project_id=none")
    assert json_response(conn, 200)["data"] == []
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

  defp document_with_revision do
    document = insert(:document)
    revision = insert(:document_revision, document: document, title: "Plan")
    %{document | latest_revision: %{revision | blocks: []}}
  end
end
