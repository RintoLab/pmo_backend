defmodule RintoPMO.Agent.EventsTest do
  use ExUnit.Case, async: true

  alias RintoPMO.Agent.Events

  doctest Events

  describe "conversation?/1" do
    test "says yes to the frames a conversation is made of" do
      for type <- Events.conversation_types() do
        assert Events.conversation?(%{"type" => type})
      end
    end

    # The reason the list exists: pi emits more than a conversation, and a
    # consumer that was never shown the rest cannot break on it.
    test "says no to everything else, including frames that do not exist yet" do
      refute Events.conversation?(%{"type" => "status_bar_update"})
      refute Events.conversation?(%{"type" => "a_frame_type_from_2027"})
      refute Events.conversation?(%{"no" => "type at all"})
    end
  end

  describe "delta/1" do
    test "tells text and thinking apart" do
      assert Events.delta(delta("text_delta", "灰度")) == {:text, "灰度"}
      assert Events.delta(delta("thinking_delta", "先看看")) == {:thinking, "先看看"}
    end

    # They are not the same thing to a reader: one is the answer arriving, the
    # other is the model working up to it.
    test "answers nil for a frame carrying neither" do
      assert Events.delta(%{"type" => "turn_start"}) == nil
      assert Events.delta(delta("text_start", nil)) == nil
      assert Events.delta(%{"assistantMessageEvent" => %{"type" => "text_delta"}}) == nil
      assert Events.delta(%{}) == nil
    end
  end

  describe "finished_message/1" do
    test "answers the message a turn ended with" do
      message = %{"content" => [%{"type" => "text", "text" => "- a task"}]}

      assert Events.finished_message(%{"type" => "turn_end", "message" => message}) == message
    end

    test "answers nil for anything else" do
      assert Events.finished_message(%{"type" => "turn_start"}) == nil
      assert Events.finished_message(%{"type" => "turn_end"}) == nil
      assert Events.finished_message(%{"type" => "turn_end", "message" => "not a map"}) == nil
    end
  end

  describe "text_of/1" do
    test "joins the text parts in order" do
      message = %{
        "content" => [
          %{"type" => "text", "text" => "## 灰度\n"},
          %{"type" => "text", "text" => "- 接流量"}
        ]
      }

      assert Events.text_of(message) == "## 灰度\n- 接流量"
    end

    # What the model worked out on the way is not part of the answer.
    test "leaves thinking out" do
      message = %{
        "content" => [
          %{"type" => "thinking", "thinking" => "先看看有几件事"},
          %{"type" => "text", "text" => "- a task"}
        ]
      }

      assert Events.text_of(message) == "- a task"
    end

    test "answers an empty string rather than raising on a shape it cannot read" do
      assert Events.text_of(%{"content" => []}) == ""
      assert Events.text_of(%{"content" => "not a list"}) == ""
      assert Events.text_of(%{}) == ""
    end
  end

  describe "refusal/1" do
    test "answers the provider's sentence" do
      message = %{"stopReason" => "error", "errorMessage" => "429: too many requests"}

      assert Events.refusal(message) == "429: too many requests"
    end

    test "still says a refusal happened when no reason came with it" do
      assert Events.refusal(%{"stopReason" => "error"}) =~ "refused"
    end

    # Reading a missing field as failure would turn every answer into one on
    # the day it is renamed.
    test "answers nil for a message that did not say it failed" do
      assert Events.refusal(%{"stopReason" => "stop"}) == nil
      assert Events.refusal(%{"content" => []}) == nil
      assert Events.refusal(%{}) == nil
    end
  end

  defp delta(type, nil), do: %{"assistantMessageEvent" => %{"type" => type}}

  defp delta(type, text),
    do: %{
      "type" => "message_update",
      "assistantMessageEvent" => %{"type" => type, "delta" => text}
    }
end
