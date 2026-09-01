defmodule RintoPMOWeb.V1.MessageControllerTest do
  use RintoPMOWeb.ConnCase, async: true

  alias RintoPMO.Conversations.Message
  alias RintoPMO.ConversationsMock

  setup do
    conversation = insert(:conversation)

    # A stub rather than an expectation: the routes that do not exist never
    # reach the controller, and that is the point of the last test here.
    stub(ConversationsMock, :get_conversation!, fn id ->
      assert id == conversation.id
      conversation
    end)

    %{conversation: conversation}
  end

  test "GET messages lists a topic in order", %{conn: conn, conversation: conversation} do
    actor = insert(:actor)

    messages =
      for {content, position} <- [{"First", 0}, {"Second", 1}] do
        insert(:message,
          conversation: conversation,
          actor: actor,
          content: content,
          position: position,
          refs: []
        )
      end

    expect(ConversationsMock, :list_messages, fn ^conversation, %{} -> messages end)

    conn = get(conn, ~p"/api/v1/conversations/#{conversation.id}/messages")

    assert [
             %{"content" => "First", "position" => 0, "role" => "user", "refs" => []},
             %{"content" => "Second", "position" => 1}
           ] = json_response(conn, 200)["data"]
  end

  test "GET messages pages forward by position", %{conn: conn, conversation: conversation} do
    expect(ConversationsMock, :list_messages, fn ^conversation, %{after_position: 3, limit: 2} ->
      []
    end)

    conn =
      get(
        conn,
        ~p"/api/v1/conversations/#{conversation.id}/messages?after_position=3&limit=2"
      )

    assert json_response(conn, 200)["data"] == []
  end

  test "GET messages rejects a bad limit", %{conn: conn, conversation: conversation} do
    conn = get(conn, ~p"/api/v1/conversations/#{conversation.id}/messages?limit=0")

    assert %{"error" => "bad_request", "details" => %{"limit" => [_message]}} =
             json_response(conn, 400)
  end

  test "GET messages renders each ref with its payload", %{
    conn: conn,
    conversation: conversation
  } do
    actor = insert(:actor)
    document = insert(:document)
    payload = %{"type" => "document", "id" => document.id}
    document_id = document.id

    message =
      insert(:message,
        conversation: conversation,
        actor: actor,
        refs: [
          build(:message_ref,
            message: nil,
            ref_type: "document",
            ref_id: document.id,
            payload: payload
          )
        ]
      )

    expect(ConversationsMock, :list_messages, fn ^conversation, %{} -> [message] end)

    conn = get(conn, ~p"/api/v1/conversations/#{conversation.id}/messages")

    assert [%{"refs" => [ref]}] = json_response(conn, 200)["data"]
    assert ref["ref_type"] == "document"
    assert ref["ref_id"] == document_id
    assert ref["payload"] == payload
  end

  test "POST messages appends a turn with its refs", %{
    conn: conn,
    conversation: conversation,
    current_actor: current_actor
  } do
    document = insert(:document)
    ref = %{"type" => "document", "id" => document.id}

    params = %{
      "role" => "user",
      "content" => "Have a look at this",
      "refs" => [ref]
    }

    # A person's turn is theirs, and the token is what says which person.
    expected = Map.put(params, "actor_id", current_actor.id)

    message =
      insert(:message,
        conversation: conversation,
        actor: current_actor,
        content: "Have a look at this",
        refs: [build(:message_ref, message: nil, payload: ref)]
      )

    expect(ConversationsMock, :append_message, fn ^conversation, ^expected -> {:ok, message} end)

    conn = post(conn, ~p"/api/v1/conversations/#{conversation.id}/messages", params)

    assert %{"content" => "Have a look at this", "refs" => [_ref]} =
             json_response(conn, 201)["data"]
  end

  # An assistant turn is left exactly as it arrived: only whatever ran the model
  # can say which actor spoke, and forcing the caller in would credit a person
  # with a model's turn.
  test "POST messages leaves an assistant turn's attribution alone", %{
    conn: conn,
    conversation: conversation
  } do
    assistant = insert(:actor, kind: :ai)

    params = %{
      "actor_id" => assistant.id,
      "role" => "assistant",
      "content" => "Looked at it"
    }

    message =
      insert(:message,
        conversation: conversation,
        actor: assistant,
        role: :assistant,
        content: "Looked at it"
      )

    expect(ConversationsMock, :append_message, fn ^conversation, ^params -> {:ok, message} end)

    conn = post(conn, ~p"/api/v1/conversations/#{conversation.id}/messages", params)

    assert json_response(conn, 201)["data"]["actor_id"] == assistant.id
  end

  test "POST messages returns validation errors", %{conn: conn, conversation: conversation} do
    params = %{"content" => "No actor"}
    changeset = Message.changeset(params)

    expect(ConversationsMock, :append_message, fn ^conversation, ^params ->
      {:error, changeset}
    end)

    conn = post(conn, ~p"/api/v1/conversations/#{conversation.id}/messages", params)

    assert %{"error" => "validation_error", "details" => %{"role" => ["can't be blank"]}} =
             json_response(conn, 422)
  end

  test "GET messages/:id returns one turn", %{conn: conn, conversation: conversation} do
    message = insert(:message, conversation: conversation, refs: [])
    message_id = message.id

    expect(ConversationsMock, :get_message!, fn ^conversation, id ->
      assert id == message.id
      message
    end)

    conn = get(conn, ~p"/api/v1/conversations/#{conversation.id}/messages/#{message.id}")

    assert %{"id" => ^message_id} = json_response(conn, 200)["data"]
  end

  test "a message can be neither edited nor deleted", %{conn: conn, conversation: conversation} do
    message = insert(:message, conversation: conversation)

    path = "/api/v1/conversations/#{conversation.id}/messages/#{message.id}"

    assert patch(conn, path, %{}).status == 404
    assert delete(conn, path).status == 404
  end
end
