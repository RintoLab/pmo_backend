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

  test "GET annotations filters by whether it is confirmed", %{conn: conn} do
    document = expect_document()

    expect(AnnotationsMock, :list_annotations, fn ^document, %{confirmed: false} -> [] end)

    conn = get(conn, ~p"/api/v1/documents/#{document.id}/annotations?confirmed=false")
    assert json_response(conn, 200)["data"] == []
  end

  test "GET annotations rejects a confirmed filter that is not a boolean", %{conn: conn} do
    document = expect_document()

    conn = get(conn, ~p"/api/v1/documents/#{document.id}/annotations?confirmed=nope")

    assert %{"error" => "bad_request", "details" => %{"confirmed" => ["is invalid"]}} =
             json_response(conn, 400)
  end

  test "GET annotations exposes the mark and the revision behind it", %{conn: conn} do
    document = expect_document()
    revision = insert(:document_revision, document: document)

    annotation =
      insert(:annotation,
        document: document,
        confirmed_at: DateTime.utc_now(),
        confirmed_by_revision_id: revision.id
      )

    revision_id = revision.id

    expect(AnnotationsMock, :list_annotations, fn ^document, %{} -> [annotation] end)

    conn = get(conn, ~p"/api/v1/documents/#{document.id}/annotations")

    assert [%{"confirmed_at" => confirmed_at, "confirmed_by_revision_id" => ^revision_id}] =
             json_response(conn, 200)["data"]

    assert confirmed_at
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

  test "POST annotations creates a thread", %{conn: conn, current_actor: current_actor} do
    document = expect_document()
    annotation = insert(:annotation, document: document, actor: current_actor, content: "Start")
    annotation_id = annotation.id
    actor_id = current_actor.id

    expected = %{
      "actor_id" => actor_id,
      "content" => "Start",
      "selected_text" => "quote"
    }

    expect(AnnotationsMock, :create_annotation, fn ^document, ^expected -> {:ok, annotation} end)

    conn =
      post(conn, ~p"/api/v1/documents/#{document.id}/annotations", %{
        "content" => "Start",
        "selected_text" => "quote"
      })

    assert %{"id" => ^annotation_id, "content" => "Start", "replies" => []} =
             json_response(conn, 201)["data"]
  end

  # A note is credited to whoever the token says is calling, so a body naming
  # somebody else names nobody.
  test "POST annotations ignores an actor in the body", %{
    conn: conn,
    current_actor: current_actor
  } do
    document = expect_document()
    annotation = insert(:annotation, document: document, actor: current_actor, content: "Start")
    impostor = insert(:actor)
    actor_id = current_actor.id

    expect(AnnotationsMock, :create_annotation, fn ^document, %{"actor_id" => ^actor_id} ->
      {:ok, annotation}
    end)

    conn =
      post(conn, ~p"/api/v1/documents/#{document.id}/annotations", %{
        "actor_id" => impostor.id,
        "content" => "Start"
      })

    assert json_response(conn, 201)["data"]["id"] == annotation.id
  end

  test "POST annotations returns validation errors", %{conn: conn} do
    document = expect_document()
    params = %{"content" => ""}

    changeset =
      Annotation.changeset(
        Map.merge(params, %{"document_id" => document.id, "actor_id" => insert(:actor).id})
      )

    expect(AnnotationsMock, :create_annotation, fn ^document, _attrs -> {:error, changeset} end)

    conn = post(conn, ~p"/api/v1/documents/#{document.id}/annotations", params)

    assert %{
             "error" => "validation_error",
             "details" => %{"content" => ["can't be blank"]}
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

  test "PATCH annotations/:id cannot confirm through an edit", %{conn: conn} do
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
        "confirmed_at" => DateTime.utc_now()
      })

    assert %{"confirmed_at" => nil} = json_response(conn, 200)["data"]
  end

  test "POST annotations/:id/confirm records the revision that settled it", %{conn: conn} do
    document = expect_document()
    annotation = insert(:annotation, document: document)
    revision = insert(:document_revision, document: document)
    revision_id = revision.id

    confirmed = %{
      annotation
      | confirmed_at: DateTime.utc_now(),
        confirmed_by_revision_id: revision.id,
        replies: []
    }

    expect(AnnotationsMock, :get_annotation!, fn ^document, id ->
      assert id == annotation.id
      %{annotation | replies: []}
    end)

    expect(AnnotationsMock, :confirm_annotation, fn _annotation, attrs ->
      assert attrs == %{"confirmed_by_revision_id" => revision_id}
      {:ok, confirmed}
    end)

    conn =
      post(conn, ~p"/api/v1/documents/#{document.id}/annotations/#{annotation.id}/confirm", %{
        "confirmed_by_revision_id" => revision.id
      })

    assert %{"confirmed_by_revision_id" => ^revision_id} = json_response(conn, 200)["data"]
  end

  # Confirming without one is the same verb: "I looked and it needs no change"
  # is a confirmation, and the difference is the pointer's absence.
  test "POST annotations/:id/confirm without a revision names none", %{conn: conn} do
    document = expect_document()
    annotation = insert(:annotation, document: document)
    confirmed = %{annotation | confirmed_at: DateTime.utc_now(), replies: []}

    expect(AnnotationsMock, :get_annotation!, fn ^document, _id ->
      %{annotation | replies: []}
    end)

    expect(AnnotationsMock, :confirm_annotation, fn _annotation, attrs ->
      assert attrs == %{}
      {:ok, confirmed}
    end)

    conn = post(conn, ~p"/api/v1/documents/#{document.id}/annotations/#{annotation.id}/confirm")

    assert %{"confirmed_at" => confirmed_at, "confirmed_by_revision_id" => nil} =
             json_response(conn, 200)["data"]

    assert confirmed_at
  end

  test "DELETE annotations/:id/confirm takes the mark off", %{conn: conn} do
    document = expect_document()

    annotation =
      insert(:annotation,
        document: document,
        confirmed_at: DateTime.utc_now(),
        confirmed_by_revision: build(:document_revision, document: document)
      )

    reopened = %{annotation | confirmed_at: nil, confirmed_by_revision_id: nil, replies: []}

    expect(AnnotationsMock, :get_annotation!, fn ^document, _id ->
      %{annotation | replies: []}
    end)

    expect(AnnotationsMock, :unconfirm_annotation, fn _annotation -> {:ok, reopened} end)

    conn = delete(conn, ~p"/api/v1/documents/#{document.id}/annotations/#{annotation.id}/confirm")

    assert %{"confirmed_at" => nil, "confirmed_by_revision_id" => nil} =
             json_response(conn, 200)["data"]
  end

  test "POST annotations/:id/reply answers with the job", %{conn: conn} do
    document = expect_document()
    annotation = insert(:annotation, document: document)

    expect(AnnotationsMock, :get_annotation!, fn ^document, _id ->
      %{annotation | replies: []}
    end)

    expect(AnnotationsMock, :request_reply, fn _annotation ->
      {:ok, queued_job(annotation.id)}
    end)

    conn = post(conn, ~p"/api/v1/documents/#{document.id}/annotations/#{annotation.id}/reply")

    assert %{"id" => 42, "status" => "running"} = json_response(conn, 202)["data"]
  end

  # A condition of asking, not an outcome, so it is answered here rather than
  # queued and failed somewhere the person who clicked is not looking.
  test "POST annotations/:id/reply says when nobody holds the role", %{conn: conn} do
    document = expect_document()
    annotation = insert(:annotation, document: document)

    expect(AnnotationsMock, :get_annotation!, fn ^document, _id ->
      %{annotation | replies: []}
    end)

    expect(AnnotationsMock, :request_reply, fn _annotation ->
      {:error, :no_annotation_actor, %{}}
    end)

    conn = post(conn, ~p"/api/v1/documents/#{document.id}/annotations/#{annotation.id}/reply")

    assert %{"error" => "no_annotation_actor"} = json_response(conn, 422)
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

  # Built rather than inserted, like `TaskControllerTest`: the controller only
  # reads it, and Oban's queues are off in test so nothing would run it anyway.
  defp queued_job(annotation_id) do
    %Oban.Job{
      id: 42,
      worker: "RintoPMO.Annotations.ReplyWorker",
      queue: "default",
      state: "available",
      args: %{"annotation_id" => annotation_id},
      errors: [],
      priority: 0,
      inserted_at: ~U[2026-08-28 09:00:00.000000Z],
      scheduled_at: ~U[2026-08-28 09:00:00.000000Z]
    }
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
