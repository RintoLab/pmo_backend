defmodule RintoPMO.Agent.Events do
  @moduledoc """
  The names pi gives things, in one place.

  pi speaks the same event vocabulary down both of its machine-readable
  channels -- `--mode rpc`, which `RintoPMO.Agent.PiSession` holds open for a
  conversation, and `--mode json`, which `RintoPMO.Agent.WbsGenerator` reads
  from a one-shot call. The transports have nothing in common and should not
  be made to; the words do, and were spelled out separately in both until this
  existed.

  That is the whole job: when a pi release renames `message_update`, this is
  the file that changes, and the compiler finds everyone who cared. Spread
  across two modules, the second one is a live dependency whose next reader
  has no reason to know the first one exists.

  ## These names are pi's, and pi promises nothing

  They are its internal frame types, not a published interface, so every
  reader here is written to fail soft. Nothing raises on an unrecognised
  shape: the answers are `nil` and "no", which callers already have to handle
  because a frame can legitimately be neither. A pi that renames an event
  costs a feature -- streaming, say -- and not a breakdown.

  The risk this concentrates is not a new one. `PiSession` has depended on
  these names for as long as it has existed; there is now one more reader and
  one fewer place to look.
  """

  @typedoc "One decoded line of pi's output."
  @type frame :: map()

  @typedoc "What the assistant is doing, when a frame says."
  @type delta :: {:text, String.t()} | {:thinking, String.t()}

  # What a conversation is made of. Everything else pi emits -- status bars,
  # widgets, frame types that do not exist yet -- is somebody else's business.
  @conversation ~w(message_start message_update message_end turn_start turn_end)

  @doc """
  The frame types that make up a conversation.

  What `PiSession` forwards to its subscribers, and the reason it forwards a
  list rather than everything: a new pi release or a newly installed extension
  can add frames, and a consumer that was never shown them cannot break on
  them.
  """
  @spec conversation_types() :: [String.t()]
  def conversation_types, do: @conversation

  @doc """
  Whether a frame is part of the conversation.
  """
  @spec conversation?(frame()) :: boolean()
  def conversation?(%{"type" => type}), do: type in @conversation
  def conversation?(_frame), do: false

  @doc """
  What the assistant just produced, if this frame carries anything.

  Text and thinking are told apart rather than merged, because they are not
  the same thing to a reader: one is the answer arriving, the other is the
  model working up to it. A caller that only wants to know the call is alive
  can ignore the tag; one that is showing somebody the answer must not.
  """
  @spec delta(frame()) :: delta() | nil
  def delta(%{"assistantMessageEvent" => %{"type" => "text_delta", "delta" => text}})
      when is_binary(text),
      do: {:text, text}

  def delta(%{"assistantMessageEvent" => %{"type" => "thinking_delta", "delta" => text}})
      when is_binary(text),
      do: {:thinking, text}

  def delta(_frame), do: nil

  @doc """
  The finished assistant message, when a frame is the end of a turn.

  The whole of what was said, which is why it is worth preferring over the
  pieces: deltas are how it arrives, not what it is.
  """
  @spec finished_message(frame()) :: map() | nil
  def finished_message(%{"type" => "turn_end", "message" => %{} = message}), do: message
  def finished_message(_frame), do: nil

  @doc """
  A message's text, in order, with thinking left out.

  Thinking is a content part of its own. What the model worked out on the way
  is not part of the answer, and a reader that concatenated both would file
  the reasoning as though the model had said it.
  """
  @spec text_of(map()) :: String.t()
  def text_of(%{"content" => content}) when is_list(content) do
    Enum.map_join(content, fn
      %{"type" => "text", "text" => text} when is_binary(text) -> text
      _not_text -> ""
    end)
  end

  def text_of(_message), do: ""

  @doc """
  Why a finished message is a refusal, or `nil` when it is not one.

  Worth knowing about because of where it hides: a provider that refuses does
  not necessarily make pi fail. Under `--mode json` pi exits **zero** and says
  so only here, so a caller reading the exit code alone sees a successful call
  that produced nothing.

  Only a stated error counts. A message with no `stopReason` is an older or a
  newer pi, and reading that as failure would turn every answer into one on
  the day the field is renamed.
  """
  @spec refusal(map()) :: String.t() | nil
  def refusal(%{"stopReason" => "error", "errorMessage" => message}) when is_binary(message),
    do: message

  def refusal(%{"stopReason" => "error"}), do: "the provider refused without saying why"
  def refusal(_message), do: nil
end
