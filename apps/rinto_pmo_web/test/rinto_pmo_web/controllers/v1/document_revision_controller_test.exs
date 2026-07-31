defmodule RintoPMOWeb.V1.DocumentRevisionControllerTest do
  use RintoPMOWeb.ConnCase, async: true

  alias RintoPMO.DocumentsMock

  test "GET revisions lists immutable revision summaries", %{conn: conn} do
    document = expect_document()
    revision = document.latest_revision

    expect(DocumentsMock, :list_revisions, fn ^document -> [revision] end)

    conn = get(conn, ~p"/api/v1/documents/#{document.id}/revisions")

    assert [%{"id" => id, "title" => "Draft"} = data] = json_response(conn, 200)["data"]
    assert id == revision.id
    refute Map.has_key?(data, "blocks")
  end

  test "GET revisions/:revision_id shows ordered blocks", %{conn: conn} do
    document = expect_document()
    revision = document.latest_revision
    block = insert(:document_block, revision: revision)
    revision = %{revision | blocks: [block]}

    expect(DocumentsMock, :get_revision!, fn ^document, id ->
      assert id == revision.id
      revision
    end)

    conn = get(conn, ~p"/api/v1/documents/#{document.id}/revisions/#{revision.id}")

    assert %{"blocks" => [%{"block_id" => block_id}]} = json_response(conn, 200)["data"]
    assert block_id == block.block_id
  end

  test "POST revisions creates a new snapshot", %{conn: conn} do
    document = expect_document()
    parent = document.latest_revision
    revision = insert(:document_revision, document: document, parent: parent, title: parent.title)
    revision = %{revision | blocks: []}

    params = %{
      "base_revision_id" => parent.id,
      "block_ops" => []
    }

    expect(DocumentsMock, :create_revision, fn ^document, ^params -> {:ok, revision} end)

    conn = post(conn, ~p"/api/v1/documents/#{document.id}/revisions", params)

    assert %{"id" => id, "parent_id" => parent_id, "blocks" => []} =
             json_response(conn, 201)["data"]

    assert id == revision.id
    assert parent_id == parent.id
  end

  test "POST revisions renders stale document conflicts", %{conn: conn} do
    document = expect_document()
    current_revision_id = document.latest_revision.id
    params = %{"base_revision_id" => UUIDv7.generate(), "block_ops" => []}

    expect(DocumentsMock, :create_revision, fn ^document, ^params ->
      {:error, :stale_document, %{current_revision_id: current_revision_id}}
    end)

    conn = post(conn, ~p"/api/v1/documents/#{document.id}/revisions", params)

    assert %{
             "error" => "stale_document",
             "details" => %{"current_revision_id" => ^current_revision_id}
           } = json_response(conn, 409)
  end

  defp expect_document do
    document = insert(:document)
    revision = insert(:document_revision, document: document, title: "Draft")
    document = %{document | latest_revision: %{revision | blocks: []}}

    expect(DocumentsMock, :get_document!, fn id ->
      assert id == document.id
      document
    end)

    document
  end
end
