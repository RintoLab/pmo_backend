defmodule RintoPMOWeb.V1.AnnotationControllerTest do
  use RintoPMOWeb.ConnCase, async: true

  alias RintoPMO.Annotations.Annotation
  alias RintoPMO.AnnotationsMock
  alias RintoPMO.DocumentsMock

  test "GET annotations lists summaries without replies", %{conn: conn} do
    document = expect_document()
    annotation = insert(:annotation, document: document, content: "Note")
    annotation_id = annotation.id

    expect(AnnotationsMock, :list_annotations, fn ^document, %{} -> [annotation] end)

    conn = get(conn, ~p"/api/v1/documents/#{document.id}/annotations")

    assert [%{"id" => ^annotation_id, "content" => "Note"} = data] =
             json_response(conn, 200)["data"]

    refute Map.has_key?(data, "replies")
  end

  test "GET annotations filters by block_id", %{conn: conn} do
    document = expect_document()
    block_id = UUIDv7.generate()

    expect(AnnotationsMock, :list_annotations, fn ^document, %{block_id: ^block_id} -> [] end)

    conn = get(conn, ~p"/api/v1/documents/#{document.id}/annotations?block_id=#{block_id}")
    assert json_response(conn, 200)["data"] == []
  end

  test "GET annotations/:id includes ordered replies", %{conn: conn} do
    document = expect_document()
    annotation = insert(:annotation, document: document)
    reply = insert(:annotation_reply, annotation: annotation, content: "Follow-up", position: 0)
    annotation = %{annotation | replies: [reply]}
    annotation_id = annotation.id
    reply_id = reply.id

    expect(AnnotationsMock, :get_annotation!, fn ^document, id ->
      assert id == annotation.id
      annotation
    end)

    conn = get(conn, ~p"/api/v1/documents/#{document.id}/annotations/#{annotation.id}")

    assert %{
             "id" => ^annotation_id,
             "replies" => [%{"id" => ^reply_id, "content" => "Follow-up", "position" => 0}]
           } = json_response(conn, 200)["data"]
  end

  test "POST annotations creates a thread", %{conn: conn} do
    document = expect_document()
    actor = insert(:actor)
    annotation = insert(:annotation, document: document, actor: actor, content: "Start")
    annotation_id = annotation.id

    params = %{
      "actor_id" => actor.id,
      "content" => "Start",
      "selected_text" => "quote"
    }

    expect(AnnotationsMock, :create_annotation, fn ^document, ^params -> {:ok, annotation} end)

    conn = post(conn, ~p"/api/v1/documents/#{document.id}/annotations", params)

    assert %{"id" => ^annotation_id, "content" => "Start", "replies" => []} =
             json_response(conn, 201)["data"]
  end

  test "POST annotations returns validation errors", %{conn: conn} do
    document = expect_document()
    params = %{"content" => "Missing actor"}
    changeset = Annotation.changeset(Map.put(params, "document_id", document.id))

    expect(AnnotationsMock, :create_annotation, fn ^document, ^params -> {:error, changeset} end)

    conn = post(conn, ~p"/api/v1/documents/#{document.id}/annotations", params)

    assert %{
             "error" => "validation_error",
             "details" => %{"actor_id" => ["can't be blank"]}
           } = json_response(conn, 422)
  end

  test "PATCH annotations/:id updates content", %{conn: conn} do
    document = expect_document()
    annotation = insert(:annotation, document: document, content: "Old")
    updated = %{annotation | content: "New", replies: []}
    params = %{"content" => "New"}

    expect(AnnotationsMock, :get_annotation!, fn ^document, id ->
      assert id == annotation.id
      %{annotation | replies: []}
    end)

    expect(AnnotationsMock, :update_annotation, fn _annotation, ^params -> {:ok, updated} end)

    conn = patch(conn, ~p"/api/v1/documents/#{document.id}/annotations/#{annotation.id}", params)

    assert %{"content" => "New", "replies" => []} = json_response(conn, 200)["data"]
  end

  test "DELETE annotations/:id returns 204", %{conn: conn} do
    document = expect_document()
    annotation = insert(:annotation, document: document)

    expect(AnnotationsMock, :get_annotation!, fn ^document, id ->
      assert id == annotation.id
      %{annotation | replies: []}
    end)

    expect(AnnotationsMock, :delete_annotation, fn _annotation -> {:ok, annotation} end)

    conn = delete(conn, ~p"/api/v1/documents/#{document.id}/annotations/#{annotation.id}")
    assert response(conn, 204) == ""
  end

  defp expect_document do
    document = insert(:document)

    expect(DocumentsMock, :get_document!, fn id ->
      assert id == document.id
      document
    end)

    document
  end
end
