defmodule RintoPMOWeb.V1.ConversationControllerTest do
  use RintoPMOWeb.ConnCase, async: true

  alias RintoPMO.Conversations.Conversation
  alias RintoPMO.ConversationsMock

  test "GET conversations lists topics", %{conn: conn} do
    conversation = insert(:conversation, title: "Tighten §3")
    conversation_id = conversation.id

    expect(ConversationsMock, :list_conversations, fn %{} -> [conversation] end)

    conn = get(conn, ~p"/api/v1/conversations")

    assert [%{"id" => ^conversation_id, "title" => "Tighten §3", "hot" => false}] =
             json_response(conn, 200)["data"]
  end

  test "GET conversations filters by actor", %{conn: conn} do
    actor = insert(:actor)
    actor_id = actor.id

    expect(ConversationsMock, :list_conversations, fn %{actor_id: ^actor_id} -> [] end)

    conn = get(conn, ~p"/api/v1/conversations?actor_id=#{actor.id}")
    assert json_response(conn, 200)["data"] == []
  end

  test "GET conversations rejects a malformed actor id", %{conn: conn} do
    conn = get(conn, ~p"/api/v1/conversations?actor_id=nope")

    assert %{"error" => "bad_request", "details" => %{"actor_id" => ["is invalid"]}} =
             json_response(conn, 400)
  end

  test "GET conversations/:id returns one topic", %{conn: conn} do
    conversation = insert(:conversation)
    conversation_id = conversation.id

    expect(ConversationsMock, :get_conversation!, fn id ->
      assert id == conversation.id
      conversation
    end)

    conn = get(conn, ~p"/api/v1/conversations/#{conversation.id}")

    assert %{"id" => ^conversation_id} = json_response(conn, 200)["data"]
  end

  test "a topic hangs off no document", %{conn: conn} do
    conversation = insert(:conversation)

    expect(ConversationsMock, :get_conversation!, fn _id -> conversation end)

    conn = get(conn, ~p"/api/v1/conversations/#{conversation.id}")
    data = json_response(conn, 200)["data"]

    refute Map.has_key?(data, "document_id")
    refute Map.has_key?(data, "annotation_id")
  end

  test "POST conversations starts a topic", %{conn: conn} do
    actor = insert(:actor)
    conversation = insert(:conversation, actor: actor, title: "Compare A and B")
    conversation_id = conversation.id
    params = %{"title" => "Compare A and B", "actor_id" => actor.id}

    expect(ConversationsMock, :create_conversation, fn ^params -> {:ok, conversation} end)

    conn = post(conn, ~p"/api/v1/conversations", params)

    assert %{"id" => ^conversation_id, "title" => "Compare A and B"} =
             json_response(conn, 201)["data"]
  end

  test "POST conversations returns validation errors", %{conn: conn} do
    params = %{"title" => String.duplicate("x", 300)}
    changeset = Conversation.changeset(params)

    expect(ConversationsMock, :create_conversation, fn ^params -> {:error, changeset} end)

    conn = post(conn, ~p"/api/v1/conversations", params)

    assert %{"error" => "validation_error", "details" => %{"title" => [_message]}} =
             json_response(conn, 422)
  end

  test "PATCH conversations/:id renames a topic", %{conn: conn} do
    conversation = insert(:conversation, title: "Old")
    renamed = %{conversation | title: "New"}
    params = %{"title" => "New"}

    expect(ConversationsMock, :get_conversation!, fn _id -> conversation end)

    expect(ConversationsMock, :update_conversation, fn _conversation, ^params ->
      {:ok, renamed}
    end)

    conn = patch(conn, ~p"/api/v1/conversations/#{conversation.id}", params)

    assert %{"title" => "New"} = json_response(conn, 200)["data"]
  end

  test "POST conversations/:id/close cools the topic and keeps it", %{conn: conn} do
    conversation = insert(:conversation, pi_session_id: nil)
    cooled = %{conversation | pi_session_id: nil}

    expect(ConversationsMock, :get_conversation!, fn _id -> conversation end)
    expect(ConversationsMock, :detach_session, fn _conversation -> {:ok, cooled} end)

    conn = post(conn, ~p"/api/v1/conversations/#{conversation.id}/close")

    assert %{"pi_session_id" => nil, "hot" => false} = json_response(conn, 200)["data"]
  end

  test "there is no open route -- sending a message is what heats a topic", %{conn: conn} do
    conversation = insert(:conversation)

    assert post(conn, "/api/v1/conversations/#{conversation.id}/open", %{}).status == 404
  end

  test "there is no delete route for a conversation", %{conn: conn} do
    conversation = insert(:conversation)

    assert delete(conn, "/api/v1/conversations/#{conversation.id}").status == 404
  end
end
