defmodule RintoPMO.Conversations.Recorder do
  @moduledoc """
  Writes what a pi session says into the conversation carrying it.

  ## Why this is its own process

  It is not in `RintoPMOWeb.PiSessionChannel` because one session can be joined
  by several channels at once -- two browser tabs on the same topic -- and each
  would write the same message again. There is exactly one recorder per
  conversation, so exactly one writer.

  It is not in `RintoPMO.Agent.PiSession` either. That module is transport: it
  manages an OS process and forwards frames, and giving it a database
  dependency would tie pi's lifecycle to the repo's.

  ## What it writes

  Answers only, and only when they are complete. `message_end` carries the
  whole finalised message, so there is nothing to accumulate from the
  `message_update` deltas -- those are a high-frequency stream that would cost
  a great deal to store and answer no question later.

  A conversation here is meant to read as what was asked and what was
  answered. Everything else pi emits is working: thinking is its private
  reasoning, tool calls and their results are how it went and looked, and the
  narration that accompanies a tool call ("let me check the document") is not
  an answer either. All of it is dropped; see `role/1` and `text/1`.

  User messages are written by whoever sent the prompt, not here. The refs that
  came with a prompt are known only at that point, and a message without its
  refs cannot be replayed.

  Roles other than `user` and `assistant` -- tool results, bash executions --
  are skipped: they are pi's working, not the conversation.
  """

  use GenServer

  alias RintoPMO.Agent.PiSession
  alias RintoPMO.Conversations.Conversation
  alias RintoPMO.Utils

  require Logger

  @registry __MODULE__.Registry

  @type option ::
          {:conversation_id, UUIDv7.t()}
          | {:session_id, PiSession.id()}
          | {:actor_id, UUIDv7.t()}
          | {:pubsub, atom()}

  @doc """
  Starts a recorder. Prefer `RintoPMO.Conversations.Recorder.Supervisor.start_recorder/1`.

  `actor_id` is the AI actor assistant turns are attributed to.
  """
  @spec start_link([option()]) :: GenServer.on_start()
  def start_link(opts) do
    conversation_id = Keyword.fetch!(opts, :conversation_id)
    GenServer.start_link(__MODULE__, opts, name: via(conversation_id))
  end

  @doc false
  def child_spec(opts) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}, restart: :temporary}
  end

  @doc """
  Returns whether a conversation currently has a recorder.
  """
  @spec recording?(UUIDv7.t()) :: boolean()
  def recording?(conversation_id) do
    case Registry.lookup(@registry, conversation_id) do
      [{pid, _value}] -> Process.alive?(pid)
      [] -> false
    end
  end

  @doc """
  Stops the recorder for a conversation, if one is running.
  """
  @spec stop(UUIDv7.t()) :: :ok
  def stop(conversation_id) do
    case Registry.lookup(@registry, conversation_id) do
      [{pid, _value}] -> GenServer.stop(pid, :normal, 5_000)
      [] -> :ok
    end
  catch
    :exit, _reason -> :ok
  end

  # GenServer

  @impl true
  def init(opts) do
    session_id = Keyword.fetch!(opts, :session_id)
    pubsub = Keyword.get(opts, :pubsub, RintoPMO.PubSub)

    :ok = PiSession.subscribe(session_id, pubsub)

    {:ok,
     %{
       conversation_id: Keyword.fetch!(opts, :conversation_id),
       session_id: session_id,
       actor_id: Keyword.fetch!(opts, :actor_id)
     }}
  end

  @impl true
  def handle_info({:pi_session, session_id, {:event, frame}}, %{session_id: session_id} = state) do
    record(frame, state)
    {:noreply, state}
  end

  # The pi process is gone, so the topic is cold. The recorder has nothing left
  # to listen to; the conversation's own row is cleared by whoever owns the
  # session lifecycle.
  def handle_info({:pi_session, session_id, {:exit, _status}}, %{session_id: session_id} = state) do
    {:stop, :normal, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  # Recording

  defp record(%{"type" => "message_end", "message" => message}, state) when is_map(message) do
    with {:ok, role} <- role(message),
         {:ok, content} <- text(message) do
      append(state, role, content)
    else
      :skip -> :ok
    end
  end

  defp record(_frame, _state), do: :ok

  # `user` is skipped here on purpose: the prompt path already wrote it, with
  # the refs this side never sees.
  #
  # Among assistant messages, only the ones that finished *answering* are kept.
  # An agentic run emits one assistant message per turn, and every turn but the
  # last stops in order to call a tool -- those messages carry narration ("let
  # me look at the document") rather than an answer, and the final message
  # restates whatever they concluded anyway. `stopReason` is the model's own
  # statement of why it stopped, so it says this directly:
  #
  #   toolUse          -> stopped to use a tool; narration
  #   stop             -> said its piece; the answer
  #   length           -> the answer, cut off by the output cap
  #   error, aborted   -> nothing worth keeping
  defp role(%{"role" => "assistant", "stopReason" => reason}) do
    if reason in ["stop", "length"], do: {:ok, :assistant}, else: :skip
  end

  # No `stopReason` at all -- a shape we have not seen. Fall back to the same
  # test the agent loop itself uses to decide whether to keep going, rather
  # than dropping a turn because a field was missing.
  defp role(%{"role" => "assistant", "content" => blocks}) when is_list(blocks) do
    if Enum.any?(blocks, &match?(%{"type" => "toolCall"}, &1)),
      do: :skip,
      else: {:ok, :assistant}
  end

  defp role(%{"role" => "assistant"}), do: {:ok, :assistant}
  defp role(_message), do: :skip

  # An assistant message is a list of content blocks. Only text is kept:
  # thinking is pi's private reasoning and tool calls are its working, neither
  # of which replay needs, and `content` is a text column besides.
  defp text(%{"content" => content}) when is_binary(content) do
    present(content)
  end

  defp text(%{"content" => blocks}) when is_list(blocks) do
    blocks
    |> Enum.filter(&match?(%{"type" => "text"}, &1))
    |> Enum.map_join("", &Map.get(&1, "text", ""))
    |> present()
  end

  defp text(_message), do: :skip

  # A turn that produced only tool calls has nothing to say and is not a turn
  # of the conversation.
  defp present(text) when is_binary(text) do
    case String.trim(text) do
      "" -> :skip
      _trimmed -> {:ok, text}
    end
  end

  defp append(state, role, content) do
    conversation = %Conversation{id: state.conversation_id}

    case conversations().append_message(conversation, %{
           actor_id: state.actor_id,
           role: role,
           content: content
         }) do
      {:ok, _message} ->
        :ok

      {:error, changeset} ->
        # A dropped turn must not take the live session with it: pi is still
        # talking to a human who would rather keep the conversation than have
        # it end over a failed insert.
        Logger.warning(
          "conversation #{state.conversation_id}: dropped a turn, " <>
            inspect(changeset.errors)
        )

        :ok
    end
  end

  defp conversations, do: Utils.module(:conversations)

  defp via(conversation_id), do: {:via, Registry, {@registry, conversation_id}}
end
