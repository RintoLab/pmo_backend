defmodule RintoPMOWeb.V1.ConversationControllerTest do
  use RintoPMOWeb.ConnCase, async: true

  alias RintoPMO.Conversations.Conversation
  alias RintoPMO.ConversationsMock
  alias RintoPMO.DocumentsMock

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

  # Derived from the topic's refs, so it stays on the global collection: there
  # is no /documents/:id/conversations, because a topic is not one document's.
  test "GET conversations filters by document", %{conn: conn} do
    conversation = insert(:conversation)
    conversation_id = conversation.id
    document = insert(:document)
    document_id = document.id

    expect(ConversationsMock, :list_conversations, fn %{document_id: ^document_id} ->
      [conversation]
    end)

    conn = get(conn, ~p"/api/v1/conversations?document_id=#{document.id}")

    assert [%{"id" => ^conversation_id}] = json_response(conn, 200)["data"]
  end

  test "GET conversations keeps both actor and document", %{conn: conn} do
    actor = insert(:actor)
    actor_id = actor.id
    document = insert(:document)
    document_id = document.id

    expect(ConversationsMock, :list_conversations, fn filter ->
      assert filter == %{actor_id: actor_id, document_id: document_id}
      []
    end)

    conn =
      get(conn, ~p"/api/v1/conversations?actor_id=#{actor.id}&document_id=#{document.id}")

    assert json_response(conn, 200)["data"] == []
  end

  test "GET conversations rejects a malformed document id", %{conn: conn} do
    conn = get(conn, ~p"/api/v1/conversations?document_id=nope")

    assert %{"error" => "bad_request", "details" => %{"document_id" => ["is invalid"]}} =
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

  # Who started a topic is the caller, so the body no longer says and one that
  # tried to would be overruled.
  test "POST conversations starts a topic under the token holder", %{
    conn: conn,
    current_actor: actor
  } do
    conversation = insert(:conversation, actor: actor, title: "Compare A and B")
    conversation_id = conversation.id
    expected = %{"title" => "Compare A and B", "actor_id" => actor.id}

    expect(ConversationsMock, :create_conversation, fn ^expected -> {:ok, conversation} end)

    conn =
      post(conn, ~p"/api/v1/conversations", %{
        "title" => "Compare A and B",
        "actor_id" => insert(:actor).id
      })

    assert %{"id" => ^conversation_id, "title" => "Compare A and B"} =
             json_response(conn, 201)["data"]
  end

  test "POST conversations returns validation errors", %{conn: conn, current_actor: actor} do
    params = %{"title" => String.duplicate("x", 300)}
    expected = Map.put(params, "actor_id", actor.id)
    changeset = Conversation.changeset(params)

    expect(ConversationsMock, :create_conversation, fn ^expected -> {:error, changeset} end)

    conn = post(conn, ~p"/api/v1/conversations", params)

    assert %{"error" => "validation_error", "details" => %{"title" => [_message]}} =
             json_response(conn, 422)
  end

  test "POST conversations starts a plain chat without an assistant actor", %{
    conn: conn,
    current_actor: actor
  } do
    params = %{
      "mode" => "chat",
      "provider" => "openai",
      "model" => "gpt-5.4",
      "thinking_level" => "medium"
    }

    conversation =
      insert(:conversation,
        actor: actor,
        mode: :chat,
        assistant_actor: nil,
        provider: "openai",
        model: "gpt-5.4",
        thinking_level: "medium"
      )

    expected = Map.put(params, "actor_id", actor.id)
    expect(ConversationsMock, :create_conversation, fn ^expected -> {:ok, conversation} end)

    conn = post(conn, ~p"/api/v1/conversations", params)

    assert %{
             "mode" => "chat",
             "assistant_actor_id" => nil,
             "provider" => "openai",
             "model" => "gpt-5.4",
             "thinking_level" => "medium"
           } = json_response(conn, 201)["data"]
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

  test "PATCH conversations/:id switches plain chat model and cools the topic", %{conn: conn} do
    conversation =
      insert(:conversation,
        mode: :chat,
        assistant_actor: nil,
        provider: "openai",
        model: "gpt-5.4",
        thinking_level: "low",
        pi_session_id: nil
      )

    attrs = %{"model" => "gpt-5.5", "thinking_level" => "medium"}
    updated = %{conversation | model: "gpt-5.5", thinking_level: "medium"}
    cooled = %{updated | pi_session_id: nil}

    expect(ConversationsMock, :get_conversation!, fn _id -> conversation end)

    expect(ConversationsMock, :update_conversation, fn ^conversation, ^attrs ->
      {:ok, updated}
    end)

    expect(ConversationsMock, :detach_session, fn ^updated -> {:ok, cooled} end)

    conn = patch(conn, ~p"/api/v1/conversations/#{conversation.id}", attrs)

    assert %{
             "mode" => "chat",
             "model" => "gpt-5.5",
             "thinking_level" => "medium",
             "hot" => false
           } = json_response(conn, 200)["data"]
  end

  test "a topic says who named it", %{conn: conn} do
    conversation = insert(:conversation, title: "上线流程遗漏检查", title_source: :auto)

    expect(ConversationsMock, :get_conversation!, fn _id -> conversation end)

    conn = get(conn, ~p"/api/v1/conversations/#{conversation.id}")

    assert %{"title_source" => "auto"} = json_response(conn, 200)["data"]
  end

  test "an unnamed topic says nobody has named it", %{conn: conn} do
    conversation = insert(:conversation, title: nil, title_source: nil)

    expect(ConversationsMock, :get_conversation!, fn _id -> conversation end)

    conn = get(conn, ~p"/api/v1/conversations/#{conversation.id}")

    assert %{"title" => nil, "title_source" => nil} = json_response(conn, 200)["data"]
  end

  test "POST conversations/:id/close cools the topic and keeps it", %{conn: conn} do
    conversation = insert(:conversation, pi_session_id: nil)
    cooled = %{conversation | pi_session_id: nil}

    expect(ConversationsMock, :get_conversation!, fn _id -> conversation end)
    expect(ConversationsMock, :detach_session, fn _conversation -> {:ok, cooled} end)

    conn = post(conn, ~p"/api/v1/conversations/#{conversation.id}/close")

    assert %{"pi_session_id" => nil, "hot" => false} = json_response(conn, 200)["data"]
  end

  test "GET conversations/:id/proposals groups this topic's work by document", %{conn: conn} do
    conversation = insert(:conversation)
    document = insert(:document)
    revision = insert(:document_revision, document: document, title: "Deployment")
    proposal = insert(:block_proposal, document: document, conversation: conversation)
    proposal_id = proposal.id
    document_id = document.id

    expect(ConversationsMock, :get_conversation!, fn _id -> conversation end)

    expect(DocumentsMock, :conversation_working_set, fn _id ->
      [
        %{
          document: %{document | latest_revision: revision},
          proposals: [%{proposal: proposal, contended: true}]
        }
      ]
    end)

    conn = get(conn, ~p"/api/v1/conversations/#{conversation.id}/proposals")

    assert %{
             "document_count" => 1,
             "proposal_count" => 1,
             "documents" => [
               %{
                 "document" => %{
                   "id" => ^document_id,
                   "latest_revision" => %{"title" => "Deployment"}
                 },
                 "proposals" => [%{"id" => ^proposal_id, "contended" => true}]
               }
             ]
           } = json_response(conn, 200)["data"]
  end

  # Not the same answer as a topic with nothing standing: one means nothing is
  # waiting, the other means the id is wrong.
  test "GET conversations/:id/proposals is 404 for a topic that is not there", %{conn: conn} do
    expect(ConversationsMock, :get_conversation!, fn _id ->
      raise Ecto.NoResultsError, queryable: Conversation
    end)

    assert {404, _headers, _body} =
             assert_error_sent(:not_found, fn ->
               get(conn, ~p"/api/v1/conversations/#{UUIDv7.generate()}/proposals")
             end)
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
