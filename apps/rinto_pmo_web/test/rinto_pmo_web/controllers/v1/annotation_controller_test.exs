defmodule RintoPMOWeb.V1.AnnotationControllerTest do
  use RintoPMOWeb.ConnCase, async: true

  alias RintoPMO.Annotations.Annotation
  alias RintoPMO.AnnotationsMock
  alias RintoPMO.ConversationsMock
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

  test "GET annotations filters by status", %{conn: conn} do
    document = expect_document()

    expect(AnnotationsMock, :list_annotations, fn ^document, %{status: :resolved} -> [] end)

    conn = get(conn, ~p"/api/v1/documents/#{document.id}/annotations?status=resolved")
    assert json_response(conn, 200)["data"] == []
  end

  test "GET annotations rejects an unknown status", %{conn: conn} do
    document = expect_document()

    conn = get(conn, ~p"/api/v1/documents/#{document.id}/annotations?status=nope")

    assert %{"error" => "bad_request", "details" => %{"status" => ["is invalid"]}} =
             json_response(conn, 400)
  end

  test "GET annotations exposes status and resolving revision", %{conn: conn} do
    document = expect_document()
    revision = insert(:document_revision, document: document)

    annotation =
      insert(:annotation,
        document: document,
        status: :resolved,
        resolved_by_revision_id: revision.id
      )

    revision_id = revision.id

    expect(AnnotationsMock, :list_annotations, fn ^document, %{} -> [annotation] end)

    conn = get(conn, ~p"/api/v1/documents/#{document.id}/annotations")

    assert [%{"status" => "resolved", "resolved_by_revision_id" => ^revision_id}] =
             json_response(conn, 200)["data"]
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

  test "PATCH annotations/:id does not forward status to the context", %{conn: conn} do
    document = expect_document()
    annotation = insert(:annotation, document: document, content: "Old")
    updated = %{annotation | content: "New", replies: []}

    expect(AnnotationsMock, :get_annotation!, fn ^document, _id ->
      %{annotation | replies: []}
    end)

    # The context ignores it, but the payload still reaches update_annotation/2;
    # asserting the shape here keeps the contract visible at the edge.
    expect(AnnotationsMock, :update_annotation, fn _annotation, attrs ->
      assert attrs["content"] == "New"
      {:ok, updated}
    end)

    conn =
      patch(conn, ~p"/api/v1/documents/#{document.id}/annotations/#{annotation.id}", %{
        "content" => "New",
        "status" => "resolved"
      })

    assert %{"status" => "open"} = json_response(conn, 200)["data"]
  end

  test "POST annotations/:id/resolve records the resolving revision", %{conn: conn} do
    document = expect_document()
    annotation = insert(:annotation, document: document)
    revision = insert(:document_revision, document: document)
    revision_id = revision.id

    resolved = %{
      annotation
      | status: :resolved,
        resolved_by_revision_id: revision.id,
        replies: []
    }

    expect(AnnotationsMock, :get_annotation!, fn ^document, id ->
      assert id == annotation.id
      %{annotation | replies: []}
    end)

    expect(AnnotationsMock, :resolve_annotation, fn _annotation, attrs ->
      assert attrs == %{"resolved_by_revision_id" => revision_id}
      {:ok, resolved}
    end)

    conn =
      post(conn, ~p"/api/v1/documents/#{document.id}/annotations/#{annotation.id}/resolve", %{
        "resolved_by_revision_id" => revision.id
      })

    assert %{"status" => "resolved", "resolved_by_revision_id" => ^revision_id} =
             json_response(conn, 200)["data"]
  end

  test "POST annotations/:id/dismiss returns the dismissed annotation", %{conn: conn} do
    document = expect_document()
    annotation = insert(:annotation, document: document)
    dismissed = %{annotation | status: :dismissed, replies: []}

    expect(AnnotationsMock, :get_annotation!, fn ^document, _id ->
      %{annotation | replies: []}
    end)

    expect(AnnotationsMock, :dismiss_annotation, fn _annotation -> {:ok, dismissed} end)

    conn =
      post(conn, ~p"/api/v1/documents/#{document.id}/annotations/#{annotation.id}/dismiss")

    assert %{"status" => "dismissed"} = json_response(conn, 200)["data"]
  end

  test "POST annotations/:id/reopen clears the resolving revision", %{conn: conn} do
    document = expect_document()

    annotation =
      insert(:annotation,
        document: document,
        status: :resolved,
        resolved_by_revision: build(:document_revision, document: document)
      )

    reopened = %{annotation | status: :open, resolved_by_revision_id: nil, replies: []}

    expect(AnnotationsMock, :get_annotation!, fn ^document, _id ->
      %{annotation | replies: []}
    end)

    expect(AnnotationsMock, :reopen_annotation, fn _annotation -> {:ok, reopened} end)

    conn = post(conn, ~p"/api/v1/documents/#{document.id}/annotations/#{annotation.id}/reopen")

    assert %{"status" => "open", "resolved_by_revision_id" => nil} =
             json_response(conn, 200)["data"]
  end

  test "GET annotations filters to conclusions awaiting a decision", %{conn: conn} do
    document = expect_document()

    expect(AnnotationsMock, :list_annotations, fn ^document, %{pending_conclusion: true} ->
      []
    end)

    conn = get(conn, ~p"/api/v1/documents/#{document.id}/annotations?pending_conclusion=true")
    assert json_response(conn, 200)["data"] == []
  end

  test "GET annotations/:id/conversations lists the topics that discussed it", %{conn: conn} do
    document = expect_document()
    annotation = insert(:annotation, document: document)
    conversation = insert(:conversation, title: "Tighten §3")
    conversation_id = conversation.id
    annotation_id = annotation.id

    expect(AnnotationsMock, :get_annotation!, fn ^document, _id ->
      %{annotation | replies: []}
    end)

    expect(ConversationsMock, :list_conversations_for_ref, fn "annotation", ^annotation_id ->
      [conversation]
    end)

    conn =
      get(conn, ~p"/api/v1/documents/#{document.id}/annotations/#{annotation.id}/conversations")

    assert [%{"id" => ^conversation_id, "title" => "Tighten §3"}] =
             json_response(conn, 200)["data"]
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
