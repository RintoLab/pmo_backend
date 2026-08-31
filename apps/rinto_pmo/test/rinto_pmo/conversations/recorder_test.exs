defmodule RintoPMO.Conversations.RecorderTest do
  use RintoPMO.DataCase, async: true

  alias RintoPMO.Agent.PiSession
  alias RintoPMO.Conversations.Message
  alias RintoPMO.Conversations.Recorder
  alias RintoPMO.ConversationsMock

  @moduletag :capture_log

  setup do
    # The registry comes from the application's own supervision tree. Each test
    # uses a fresh conversation id, so they never collide in it.
    %{
      conversation_id: UUIDv7.generate(),
      session_id: "pi-recorder-#{System.unique_integer([:positive])}",
      actor_id: UUIDv7.generate()
    }
  end

  test "writes a completed assistant turn", context do
    expect_append(start_recorder(context))

    emit(context, %{
      "type" => "message_end",
      "message" => %{
        "role" => "assistant",
        "stopReason" => "stop",
        "content" => [%{"type" => "text", "text" => "Section 3 contradicts section 1."}]
      }
    })

    assert_receive {:appended, conversation_id, attrs}
    assert conversation_id == context.conversation_id
    assert attrs.role == :assistant
    assert attrs.actor_id == context.actor_id
    assert attrs.content == "Section 3 contradicts section 1."
  end

  test "records a plain-chat answer without an actor and snapshots its model", context do
    context = %{
      context
      | actor_id: nil
    }

    recorder =
      start_recorder(context,
        provider: "anthropic",
        model: "claude-sonnet-4",
        thinking_level: "medium"
      )

    expect_append(recorder)

    emit(context, %{
      "type" => "message_end",
      "message" => %{"role" => "assistant", "stopReason" => "stop", "content" => "Hello"}
    })

    assert_receive {:appended, _conversation_id, attrs}
    assert attrs.actor_id == nil
    assert attrs.provider == "anthropic"
    assert attrs.model == "claude-sonnet-4"
    assert attrs.thinking_level == "medium"
  end

  test "joins the text blocks and drops thinking and tool calls", context do
    expect_append(start_recorder(context))

    emit(context, %{
      "type" => "message_end",
      "message" => %{
        "role" => "assistant",
        "stopReason" => "stop",
        "content" => [
          %{"type" => "thinking", "thinking" => "the user wants..."},
          %{"type" => "text", "text" => "First. "},
          %{"type" => "text", "text" => "Second."}
        ]
      }
    })

    assert_receive {:appended, _conversation_id, %{content: "First. Second."}}
  end

  test "accepts a plain string content", context do
    expect_append(start_recorder(context))

    emit(context, %{
      "type" => "message_end",
      "message" => %{"role" => "assistant", "stopReason" => "stop", "content" => "Plain text"}
    })

    assert_receive {:appended, _conversation_id, %{content: "Plain text"}}
  end

  test "keeps an answer the output cap truncated", context do
    expect_append(start_recorder(context))

    emit(context, %{
      "type" => "message_end",
      "message" => %{
        "role" => "assistant",
        "stopReason" => "length",
        "content" => [%{"type" => "text", "text" => "It contradicts section 1 because th"}]
      }
    })

    assert_receive {:appended, _conversation_id,
                    %{content: "It contradicts section 1 because th"}}
  end

  test "skips the user turn, which the prompt path already wrote", context do
    recorder = start_recorder(context)

    emit(context, %{
      "type" => "message_end",
      "message" => %{
        "role" => "user",
        "stopReason" => "stop",
        "content" => "Please review this"
      }
    })

    assert_handled(recorder)
  end

  test "skips tool results and bash executions", context do
    recorder = start_recorder(context)

    for role <- ~w(toolResult bashExecution) do
      emit(context, %{
        "type" => "message_end",
        "message" => %{
          "role" => role,
          "stopReason" => "stop",
          "content" => [%{"type" => "text", "text" => "output"}]
        }
      })
    end

    assert_handled(recorder)
  end

  test "skips the narration that comes with a tool call", context do
    recorder = start_recorder(context)

    # Every turn of an agentic run but the last stops to call a tool. Its text
    # is narration, and the final answer restates whatever it concluded.
    emit(context, %{
      "type" => "message_end",
      "message" => %{
        "role" => "assistant",
        "stopReason" => "toolUse",
        "content" => [
          %{"type" => "text", "text" => "让我看一下文档"},
          %{"type" => "toolCall", "id" => "call_1", "name" => "read"}
        ]
      }
    })

    assert_handled(recorder)
  end

  test "skips errored and aborted turns", context do
    recorder = start_recorder(context)

    for reason <- ["error", "aborted"] do
      emit(context, %{
        "type" => "message_end",
        "message" => %{
          "role" => "assistant",
          "stopReason" => reason,
          "content" => [%{"type" => "text", "text" => "half a sen"}]
        }
      })
    end

    assert_handled(recorder)
  end

  test "falls back to the tool-call test when stopReason is missing", context do
    recorder = start_recorder(context)

    # A shape we have not seen should not cost us a turn, so the fallback is
    # the same test the agent loop uses to decide whether to keep going.
    emit(context, %{
      "type" => "message_end",
      "message" => %{
        "role" => "assistant",
        "content" => [%{"type" => "toolCall", "id" => "call_1", "name" => "read"}]
      }
    })

    assert_handled(recorder)

    expect_append(recorder)

    emit(context, %{
      "type" => "message_end",
      "message" => %{
        "role" => "assistant",
        "content" => [%{"type" => "text", "text" => "No tool call here"}]
      }
    })

    assert_receive {:appended, _conversation_id, %{content: "No tool call here"}}
  end

  test "ignores streaming deltas and turn boundaries", context do
    recorder = start_recorder(context)

    emit(context, %{
      "type" => "message_update",
      "message" => %{
        "role" => "assistant",
        "stopReason" => "stop",
        "content" => [%{"type" => "text", "text" => "par"}]
      },
      "assistantMessageEvent" => %{"type" => "text_delta", "delta" => "par"}
    })

    emit(context, %{"type" => "turn_start"})
    emit(context, %{"type" => "turn_end", "message" => %{"role" => "assistant"}})

    assert_handled(recorder)
  end

  test "stops when the pi process exits", context do
    recorder = start_recorder(context)
    ref = Process.monitor(recorder)

    Phoenix.PubSub.broadcast(
      RintoPMO.PubSub,
      PiSession.topic(context.session_id),
      {:pi_session, context.session_id, {:exit, {:exit, 0}}}
    )

    assert_receive {:DOWN, ^ref, :process, ^recorder, :normal}
    refute Recorder.recording?(context.conversation_id)
  end

  test "a failed insert drops the turn without taking the recorder down", context do
    recorder = start_recorder(context)

    expect(ConversationsMock, :append_message, fn _conversation, _attrs ->
      {:error, Message.changeset(%{})}
    end)

    Mox.allow(ConversationsMock, self(), recorder)

    emit(context, %{
      "type" => "message_end",
      "message" => %{"role" => "assistant", "stopReason" => "stop", "content" => "Something"}
    })

    assert_handled(recorder)
    assert Process.alive?(recorder)
  end

  test "registers itself under the conversation", context do
    _recorder = start_recorder(context)

    assert Recorder.recording?(context.conversation_id)
    refute Recorder.recording?(UUIDv7.generate())

    :ok = Recorder.stop(context.conversation_id)
    refute Recorder.recording?(context.conversation_id)
  end

  defp start_recorder(context, opts \\ []) do
    start_supervised!(
      {Recorder,
       [
         conversation_id: context.conversation_id,
         session_id: context.session_id,
         actor_id: context.actor_id
       ] ++ opts}
    )
  end

  # Reports each append back to the test, and lets the recorder -- a process
  # the test does not own -- use the mock.
  defp expect_append(recorder) do
    test_pid = self()

    expect(ConversationsMock, :append_message, fn conversation, attrs ->
      send(test_pid, {:appended, conversation.id, attrs})

      {:ok,
       %Message{
         id: UUIDv7.generate(),
         conversation_id: conversation.id,
         actor_id: attrs.actor_id,
         role: attrs.role,
         content: attrs.content,
         position: 0
       }}
    end)

    Mox.allow(ConversationsMock, test_pid, recorder)
    recorder
  end

  # No expectation was set, so the strict mock would have raised on any call.
  # Waiting for the frame to be handled is what makes that meaningful --
  # otherwise the test passes simply by finishing first.
  defp assert_handled(recorder) do
    assert _state = :sys.get_state(recorder)
  end

  defp emit(context, frame) do
    Phoenix.PubSub.broadcast(
      RintoPMO.PubSub,
      PiSession.topic(context.session_id),
      {:pi_session, context.session_id, {:event, frame}}
    )
  end
end
