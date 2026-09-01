defmodule RintoPMOWeb.V1.AnnotationReplyControllerTest do
  use RintoPMOWeb.ConnCase, async: true

  alias RintoPMO.AnnotationsMock
  alias RintoPMO.DocumentsMock

  test "POST replies creates a follow-up credited to the caller", %{
    conn: conn,
    current_actor: current_actor
  } do
    document = insert(:document)
    annotation = insert(:annotation, document: document)
    reply = insert(:annotation_reply, annotation: annotation, actor: current_actor, position: 0)
    reply_id = reply.id

    # An actor in the body is overwritten: a follow-up is by whoever is calling.
    params = %{"actor_id" => insert(:actor).id, "content" => "Follow-up"}
    expected = %{"actor_id" => current_actor.id, "content" => "Follow-up"}

    expect(DocumentsMock, :get_document!, fn id ->
      assert id == document.id
      document
    end)

    expect(AnnotationsMock, :get_annotation!, fn ^document, id ->
      assert id == annotation.id
      %{annotation | replies: []}
    end)

    expect(AnnotationsMock, :create_reply, fn _annotation, ^expected -> {:ok, reply} end)

    conn =
      post(
        conn,
        ~p"/api/v1/documents/#{document.id}/annotations/#{annotation.id}/replies",
        params
      )

    assert %{"id" => ^reply_id, "position" => 0, "content" => content} =
             json_response(conn, 201)["data"]

    assert content == reply.content
  end

  test "PATCH replies/:id updates content", %{conn: conn} do
    document = insert(:document)
    annotation = insert(:annotation, document: document)
    reply = insert(:annotation_reply, annotation: annotation, content: "Old", position: 0)
    updated = %{reply | content: "New"}
    params = %{"content" => "New"}

    expect(DocumentsMock, :get_document!, fn id ->
      assert id == document.id
      document
    end)

    expect(AnnotationsMock, :get_annotation!, fn ^document, id ->
      assert id == annotation.id
      %{annotation | replies: []}
    end)

    expect(AnnotationsMock, :get_reply!, fn _annotation, id ->
      assert id == reply.id
      reply
    end)

    expect(AnnotationsMock, :update_reply, fn ^reply, ^params -> {:ok, updated} end)

    conn =
      patch(
        conn,
        ~p"/api/v1/documents/#{document.id}/annotations/#{annotation.id}/replies/#{reply.id}",
        params
      )

    assert %{"content" => "New", "position" => 0} = json_response(conn, 200)["data"]
  end

  test "DELETE replies/:id returns 204", %{conn: conn} do
    document = insert(:document)
    annotation = insert(:annotation, document: document)
    reply = insert(:annotation_reply, annotation: annotation, position: 0)

    expect(DocumentsMock, :get_document!, fn id ->
      assert id == document.id
      document
    end)

    expect(AnnotationsMock, :get_annotation!, fn ^document, id ->
      assert id == annotation.id
      %{annotation | replies: []}
    end)

    expect(AnnotationsMock, :get_reply!, fn _annotation, id ->
      assert id == reply.id
      reply
    end)

    expect(AnnotationsMock, :delete_reply, fn ^reply -> {:ok, reply} end)

    conn =
      delete(
        conn,
        ~p"/api/v1/documents/#{document.id}/annotations/#{annotation.id}/replies/#{reply.id}"
      )

    assert response(conn, 204) == ""
  end
end
