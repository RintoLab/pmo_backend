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

  test "POST commit turns the proposals into a revision", %{conn: conn} do
    document = expect_document()
    conversation = insert(:conversation)
    annotation = insert(:annotation, document: document)
    actor = insert(:actor)

    revision =
      insert(:document_revision,
        document: document,
        change_summary: "Tightened §3",
        source_conversation: conversation
      )

    revision_id = revision.id
    conversation_id = conversation.id

    params = %{
      "actor_id" => actor.id,
      "base_revision_id" => document.latest_revision.id,
      "source_conversation_id" => conversation.id,
      "resolve_annotation_ids" => [annotation.id],
      "change_summary" => "Tightened §3"
    }

    expect(DocumentsMock, :commit_proposals, fn ^document, ^params ->
      {:ok, %{revision | blocks: []}}
    end)

    conn = post(conn, ~p"/api/v1/documents/#{document.id}/commit", params)

    assert %{
             "id" => ^revision_id,
             "change_summary" => "Tightened §3",
             "source_conversation_id" => ^conversation_id
           } = json_response(conn, 201)["data"]
  end

  test "POST commit refuses a block nobody has decided", %{conn: conn} do
    document = expect_document()
    block_id = UUIDv7.generate()
    params = %{"actor_id" => insert(:actor).id, "base_revision_id" => UUIDv7.generate()}

    expect(DocumentsMock, :commit_proposals, fn ^document, ^params ->
      {:error, :unresolved_contention, %{block_ids: [block_id]}}
    end)

    conn = post(conn, ~p"/api/v1/documents/#{document.id}/commit", params)

    # A contention is a question for a person, not something to retry.
    assert %{
             "error" => "unresolved_contention",
             "details" => %{"block_ids" => [^block_id]}
           } = json_response(conn, 409)
  end

  test "POST commit reports having nothing to commit", %{conn: conn} do
    document = expect_document()
    params = %{"actor_id" => insert(:actor).id, "base_revision_id" => UUIDv7.generate()}

    expect(DocumentsMock, :commit_proposals, fn ^document, ^params ->
      {:error, :nothing_to_commit, %{}}
    end)

    conn = post(conn, ~p"/api/v1/documents/#{document.id}/commit", params)

    assert %{"error" => "nothing_to_commit"} = json_response(conn, 422)
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
