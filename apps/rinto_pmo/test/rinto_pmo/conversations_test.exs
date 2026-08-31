defmodule RintoPMO.ConversationsTest do
  use RintoPMO.DataCase, async: true

  alias RintoPMO.Conversations
  alias RintoPMO.Conversations.Conversation
  alias RintoPMO.ProjectsMock

  describe "conversations" do
    test "creates a topic without belonging to any document" do
      actor = insert(:actor)

      assert {:ok, %Conversation{} = conversation} =
               Conversations.create_conversation(%{title: "Tighten §3", actor_id: actor.id})

      assert conversation.title == "Tighten §3"
      assert conversation.actor_id == actor.id
      assert conversation.pi_session_id == nil

      refute Map.has_key?(conversation, :document_id)
      refute Map.has_key?(conversation, :annotation_id)
    end

    test "creates a topic with no actor and no title" do
      assert {:ok, conversation} = Conversations.create_conversation(%{})
      assert conversation.title == nil
      assert conversation.actor_id == nil
      assert conversation.mode == :actor
    end

    test "creates a plain chat with inline model configuration" do
      assert {:ok, conversation} =
               Conversations.create_conversation(%{
                 mode: :chat,
                 provider: "anthropic",
                 model: "claude-sonnet-4",
                 thinking_level: "medium"
               })

      assert conversation.mode == :chat
      assert conversation.assistant_actor_id == nil
      assert conversation.provider == "anthropic"
      assert conversation.model == "claude-sonnet-4"
      assert conversation.thinking_level == "medium"
    end

    test "plain chat requires a complete inline model configuration and no assistant actor" do
      actor = insert(:actor, kind: :ai)

      assert {:error, incomplete} =
               Conversations.create_conversation(%{mode: :chat, provider: "anthropic"})

      assert "can't be blank" in errors_on(incomplete).model
      assert "can't be blank" in errors_on(incomplete).thinking_level

      assert {:error, attributed} =
               Conversations.create_conversation(%{
                 mode: :chat,
                 assistant_actor_id: actor.id,
                 provider: "anthropic",
                 model: "claude-sonnet-4",
                 thinking_level: "medium"
               })

      assert "must be blank in chat mode" in errors_on(attributed).assistant_actor_id
    end

    test "switching modes clears the old mode's configuration" do
      assistant = insert(:actor, kind: :ai)

      chat =
        insert(:conversation,
          mode: :chat,
          assistant_actor: nil,
          provider: "openai",
          model: "gpt-5.4",
          thinking_level: "medium"
        )

      assert {:ok, actor_topic} =
               Conversations.update_conversation(chat, %{
                 "mode" => "actor",
                 "assistant_actor_id" => assistant.id
               })

      assert actor_topic.mode == :actor
      assert actor_topic.assistant_actor_id == assistant.id
      assert actor_topic.provider == nil
      assert actor_topic.model == nil
      assert actor_topic.thinking_level == nil
    end

    test "renames a topic" do
      conversation = insert(:conversation, title: "Old")

      assert {:ok, updated} = Conversations.update_conversation(conversation, %{title: "New"})
      assert updated.title == "New"
    end

    test "lists newest first and filters by actor" do
      actor = insert(:actor)
      other = insert(:actor)

      mine = insert(:conversation, actor: actor)
      theirs = insert(:conversation, actor: other)

      assert ids(Conversations.list_conversations(%{})) ==
               MapSet.new([mine.id, theirs.id])

      assert ids(Conversations.list_conversations(%{actor_id: actor.id})) ==
               MapSet.new([mine.id])
    end
  end

  describe "messages" do
    test "appends monotonic positions" do
      conversation = insert(:conversation)
      actor = insert(:actor)

      assert {:ok, first} = append(conversation, actor, "First")
      assert {:ok, second} = append(conversation, actor, "Second")

      assert first.position == 0
      assert second.position == 1
    end

    test "requires a role and content" do
      conversation = insert(:conversation)

      assert {:error, changeset} = Conversations.append_message(conversation, %{})
      assert "can't be blank" in errors_on(changeset).role
      assert "can't be blank" in errors_on(changeset).content
    end

    test "requires an actor for a user turn but not for an assistant turn" do
      conversation = insert(:conversation)

      assert {:error, user_changeset} =
               Conversations.append_message(conversation, %{role: :user, content: "Hello"})

      assert "can't be blank" in errors_on(user_changeset).actor_id

      assert {:ok, assistant} =
               Conversations.append_message(conversation, %{
                 role: :assistant,
                 content: "Hello",
                 provider: "anthropic",
                 model: "claude-sonnet-4",
                 thinking_level: "medium"
               })

      assert assistant.actor_id == nil
      assert assistant.provider == "anthropic"
      assert assistant.model == "claude-sonnet-4"
      assert assistant.thinking_level == "medium"
    end

    test "rejects a role outside user and assistant" do
      conversation = insert(:conversation)
      actor = insert(:actor)

      assert {:error, changeset} =
               Conversations.append_message(conversation, %{
                 actor_id: actor.id,
                 role: :toolResult,
                 content: "tool output"
               })

      assert "is invalid" in errors_on(changeset).role
    end

    test "lists in order and pages forward by position" do
      conversation = insert(:conversation)
      actor = insert(:actor)

      for text <- ~w(a b c d) do
        {:ok, _message} = append(conversation, actor, text)
      end

      assert Enum.map(Conversations.list_messages(conversation, %{}), & &1.content) ==
               ~w(a b c d)

      assert Enum.map(
               Conversations.list_messages(conversation, %{after_position: 1, limit: 2}),
               & &1.content
             ) == ~w(c d)
    end

    test "recent_messages returns the tail, still oldest first" do
      conversation = insert(:conversation)
      actor = insert(:actor)

      for text <- ~w(a b c d e) do
        {:ok, _message} = append(conversation, actor, text)
      end

      assert Enum.map(Conversations.recent_messages(conversation, 2), & &1.content) == ~w(d e)

      assert Enum.map(Conversations.recent_messages(conversation, 99), & &1.content) ==
               ~w(a b c d e)
    end

    test "scopes get_message! to its conversation" do
      conversation = insert(:conversation)
      other = insert(:conversation)
      actor = insert(:actor)

      {:ok, message} = append(conversation, actor, "Mine")

      assert Conversations.get_message!(conversation, message.id).id == message.id

      assert_raise Ecto.NoResultsError, fn ->
        Conversations.get_message!(other, message.id)
      end
    end
  end

  describe "message refs" do
    test "stores every ref with its payload intact and normalised columns" do
      conversation = insert(:conversation)
      actor = insert(:actor)
      document = insert(:document)
      annotation = insert(:annotation, document: document)
      attachment = insert(:attachment)

      refs = [
        %{"type" => "document", "id" => document.id},
        %{"type" => "annotation", "id" => annotation.id, "document_id" => document.id},
        %{"type" => "attachment", "id" => attachment.id}
      ]

      assert {:ok, message} =
               Conversations.append_message(conversation, %{
                 actor_id: actor.id,
                 role: :user,
                 content: "Look at these",
                 refs: refs
               })

      stored = Conversations.get_message!(conversation, message.id)
      assert length(stored.refs) == 3

      assert Enum.map(stored.refs, & &1.payload) == refs

      # Order is not incidental: PromptBuilder expands refs in this order, so a
      # replay has to reproduce it. It cannot ride on the ids -- UUIDv7 orders
      # only to the millisecond and all three land inside one.
      assert Enum.map(stored.refs, & &1.position) == [0, 1, 2]
      assert Enum.map(stored.refs, & &1.ref_type) == ~w(document annotation attachment)

      by_type = Map.new(stored.refs, &{&1.ref_type, &1})

      assert by_type["document"].ref_id == document.id
      assert by_type["annotation"].ref_id == annotation.id
      assert by_type["annotation"].ref_document_id == document.id
      assert by_type["attachment"].ref_id == attachment.id
    end

    test "resolves a project ref's slug to an id while keeping the slug in the payload" do
      conversation = insert(:conversation)
      actor = insert(:actor)
      project = insert(:project)

      expect(ProjectsMock, :get_project_by_slug!, fn slug ->
        assert slug == project.slug
        project
      end)

      ref = %{"type" => "project", "slug" => project.slug}

      assert {:ok, message} =
               Conversations.append_message(conversation, %{
                 actor_id: actor.id,
                 role: :user,
                 content: "About this project",
                 refs: [ref]
               })

      assert [stored] = Conversations.get_message!(conversation, message.id).refs
      assert stored.ref_type == "project"
      assert stored.ref_id == project.id
      # Neither form can be derived from the other, so both are kept.
      assert stored.payload == ref
    end

    test "keeps a ref whose project no longer resolves" do
      conversation = insert(:conversation)
      actor = insert(:actor)

      expect(ProjectsMock, :get_project_by_slug!, fn _slug ->
        raise Ecto.NoResultsError, queryable: RintoPMO.Projects.Project
      end)

      assert {:ok, message} =
               Conversations.append_message(conversation, %{
                 actor_id: actor.id,
                 role: :user,
                 content: "About a gone project",
                 refs: [%{"type" => "project", "slug" => "vanished"}]
               })

      assert [stored] = Conversations.get_message!(conversation, message.id).refs
      assert stored.ref_id == nil
      assert stored.payload == %{"type" => "project", "slug" => "vanished"}
    end

    test "stores an unknown ref type rather than rejecting the turn" do
      conversation = insert(:conversation)
      actor = insert(:actor)

      assert {:ok, message} =
               Conversations.append_message(conversation, %{
                 actor_id: actor.id,
                 role: :user,
                 content: "Future type",
                 refs: [%{"type" => "gizmo", "id" => "not-a-uuid"}]
               })

      assert [stored] = Conversations.get_message!(conversation, message.id).refs
      assert stored.ref_type == "gizmo"
      assert stored.ref_id == nil
    end
  end

  describe "reverse lookup" do
    test "finds every topic that discussed an annotation" do
      document = insert(:document)
      annotation = insert(:annotation, document: document)
      other_annotation = insert(:annotation, document: document)
      actor = insert(:actor)

      first = insert(:conversation)
      second = insert(:conversation)
      unrelated = insert(:conversation)

      ref = %{"type" => "annotation", "id" => annotation.id, "document_id" => document.id}

      for conversation <- [first, second] do
        {:ok, _message} =
          Conversations.append_message(conversation, %{
            actor_id: actor.id,
            role: :user,
            content: "Discussing it",
            refs: [ref]
          })
      end

      {:ok, _message} =
        Conversations.append_message(unrelated, %{
          actor_id: actor.id,
          role: :user,
          content: "Discussing something else",
          refs: [
            %{
              "type" => "annotation",
              "id" => other_annotation.id,
              "document_id" => document.id
            }
          ]
        })

      found = Conversations.list_conversations_for_ref("annotation", annotation.id)

      assert ids(found) == MapSet.new([first.id, second.id])
    end

    test "returns a topic once however often it referenced the thing" do
      document = insert(:document)
      annotation = insert(:annotation, document: document)
      actor = insert(:actor)
      conversation = insert(:conversation)

      ref = %{"type" => "annotation", "id" => annotation.id, "document_id" => document.id}

      for _turn <- 1..3 do
        {:ok, _message} =
          Conversations.append_message(conversation, %{
            actor_id: actor.id,
            role: :user,
            content: "Again",
            refs: [ref]
          })
      end

      assert [found] = Conversations.list_conversations_for_ref("annotation", annotation.id)
      assert found.id == conversation.id
    end
  end

  describe "hot and cold" do
    test "attaches and detaches a pi session" do
      conversation = insert(:conversation)

      assert {:ok, hot} = Conversations.attach_session(conversation, "pi-1")
      assert hot.pi_session_id == "pi-1"

      assert Conversations.get_conversation_by_session("pi-1").id == conversation.id

      assert {:ok, cold} = Conversations.detach_session(hot)
      assert cold.pi_session_id == nil
      assert Conversations.get_conversation_by_session("pi-1") == nil
    end

    test "history survives the session going away" do
      conversation = insert(:conversation)
      actor = insert(:actor)

      {:ok, hot} = Conversations.attach_session(conversation, "pi-2")
      {:ok, _message} = append(hot, actor, "Said while hot")
      {:ok, cold} = Conversations.detach_session(hot)

      assert Enum.map(Conversations.list_messages(cold, %{}), & &1.content) ==
               ["Said while hot"]
    end

    test "attaching a session leaves a replay owing, and only one caller pays it" do
      conversation = insert(:conversation)

      refute conversation.replay_pending

      {:ok, hot} = Conversations.attach_session(conversation, "pi-4")
      # A fresh pi process starts empty, so the next prompt owes it the history.
      assert hot.replay_pending

      # Two tabs prompting at once must not both decide they are the one.
      assert Conversations.claim_replay(hot)
      refute Conversations.claim_replay(hot)
      refute Conversations.get_conversation!(hot.id).replay_pending
    end

    test "cooling clears the debt with the session" do
      conversation = insert(:conversation)

      {:ok, hot} = Conversations.attach_session(conversation, "pi-5")
      {:ok, cold} = Conversations.detach_session(hot)

      # There is no process left to owe anything to.
      refute cold.replay_pending
      refute Conversations.claim_replay(cold)
    end

    test "one pi session cannot carry two topics" do
      first = insert(:conversation)
      second = insert(:conversation)

      {:ok, _hot} = Conversations.attach_session(first, "pi-3")

      assert {:error, changeset} = Conversations.attach_session(second, "pi-3")
      assert "has already been taken" in errors_on(changeset).pi_session_id
    end
  end

  defp append(conversation, actor, content) do
    Conversations.append_message(conversation, %{
      actor_id: actor.id,
      role: :user,
      content: content
    })
  end

  defp ids(conversations) do
    conversations |> Enum.map(& &1.id) |> MapSet.new()
  end
end
