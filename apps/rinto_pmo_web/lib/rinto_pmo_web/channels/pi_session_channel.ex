defmodule RintoPMOWeb.PiSessionChannel do
  @moduledoc """
  Front-end access to a `RintoPMO.Agent.PiSession`: the conversation as it
  streams, and the questions it stops to ask.

  ## Joining

      socket.channel("pi_session:" + id, {})           // attach to an existing session
      socket.channel("pi_session:" + id, {create: true}) // start it if it is not running

  A join immediately pushes the session's current state, so a client arriving
  long after a question was asked still sees it:

      {"pending_ui": [request, ...]}

  Leaving does **not** end the session. That is the point of a session: it
  outlives the browser tab, keeps the pi process warm, and holds any parked
  question until somebody answers. Ending one is the explicit `"close"` message.

  ## Client to server

    * `"prompt"` -- `%{"message" => "..."}`, the ordinary way to talk to the
      agent; optional `"refs"` name things in this system to put in front of the
      message (see `RintoPMO.Agent.PromptBuilder`), while `"images"` and
      `"streamingBehavior"` pass straight through

  A `"prompt"` carrying `"refs"` is refused outright -- `{"reason":
  "ref_not_found"}` or `{"reason": "invalid_ref"}` -- rather than sent with the
  reference silently dropped. Half a question is worse than none: the agent
  would answer confidently about a document it never saw.
    * `"command"` -- `%{"type" => "get_state", ...}`, any raw RPC command
    * `"answer"` -- `%{"ui_id" => id, "value" | "confirmed" | "cancelled" => _}`
    * `"pending_ui"` -- re-read the parked questions
    * `"close"` -- end the session and its pi process

  `"prompt"` and `"command"` reply `{"ok": response}` or `{"error": reason}`
  when pi answers, which for a prompt is after the whole turn. Replies are sent
  from a separate process, so the channel keeps delivering events -- and keeps
  accepting `"answer"` -- while a command is still in flight. Without that a
  prompt that parks on a question would block the very channel needed to
  release it.

  ## Server to client

    * `"event"` -- a conversation frame (`message_update`, `turn_end`, ...)
    * `"ui_request"` -- the agent is waiting on a human
    * `"ui_resolved"` -- `%{"ui_id" => id}`, that question is answered
    * `"exit"` -- pi ended; the channel stops with it
  """

  use RintoPMOWeb, :channel

  alias RintoPMO.Agent.PiSession
  alias RintoPMO.Agent.PromptBuilder
  alias RintoPMO.Conversations.Conversation

  @impl true
  def join("pi_session:" <> session_id, params, socket) do
    case attach(session_id, params) do
      {:ok, session_id} ->
        send(self(), :after_join)
        {:ok, assign(socket, :session_id, session_id)}

      {:error, reason} ->
        {:error, %{reason: to_string(reason)}}
    end
  end

  defp attach(session_id, params) do
    cond do
      PiSession.alive?(session_id) -> {:ok, session_id}
      params["create"] -> create(session_id)
      true -> {:error, :not_found}
    end
  end

  defp create(session_id) do
    case PiSession.Supervisor.start_session(id: session_id) do
      {:ok, _pid} -> {:ok, session_id}
      {:error, {:already_started, _pid}} -> {:ok, session_id}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def handle_info(:after_join, socket) do
    case PiSession.pending_ui(socket.assigns.session_id) do
      {:ok, requests} ->
        push(socket, "pending_ui", %{pending_ui: requests})
        {:noreply, socket}

      {:error, _reason} ->
        {:stop, :normal, socket}
    end
  end

  # The channel topic and `PiSession.topic/1` are deliberately the same string,
  # and both run on RintoPMO.PubSub, so a joined channel is already subscribed
  # to the session's broadcasts. Subscribing again here would double every
  # event.
  def handle_info({:pi_session, _id, {:event, frame}}, socket) do
    push(socket, "event", frame)
    {:noreply, socket}
  end

  def handle_info({:pi_session, _id, {:ui_request, request}}, socket) do
    push(socket, "ui_request", request)
    {:noreply, socket}
  end

  def handle_info({:pi_session, _id, {:ui_resolved, ui_id}}, socket) do
    push(socket, "ui_resolved", %{ui_id: ui_id})
    {:noreply, socket}
  end

  def handle_info({:pi_session, _id, {:exit, status}}, socket) do
    push(socket, "exit", %{status: inspect(status)})
    {:stop, :normal, socket}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  # `message` rather than `text`: pi's own `prompt` command names it that way
  # (`RpcCommand` in its `rpc-types.d.ts`), and matching its vocabulary keeps
  # this API readable against pi's protocol docs.
  @impl true
  def handle_in("prompt", %{"message" => message} = payload, socket) do
    refs = Map.get(payload, "refs", [])

    conversation = conversation_for(socket)

    build_opts = [
      # Only the first prompt after a revive carries the history, and the claim
      # is atomic so two tabs cannot both pay it.
      replay: replay_for(conversation),
      on_missing_refs: on_missing_refs(payload)
    ]

    case PromptBuilder.build(message, refs, build_opts) do
      {:ok, built} ->
        # Written before the command goes out, so the human's turn is at a
        # lower position than the reply the recorder writes for it. The replay
        # is deliberately not among the refs recorded: the system restored that
        # context, the human did not cite it.
        record_prompt(conversation, message, refs, payload)

        command =
          payload
          |> Map.take(["streamingBehavior"])
          |> Map.merge(%{"type" => "prompt", "message" => built.message})
          |> put_images(built.images ++ Map.get(payload, "images", []))

        dispatch(socket, command)

      {:error, reason, details} ->
        {:reply, {:error, %{reason: to_string(reason), details: details}}, socket}
    end
  end

  def handle_in("command", %{"type" => _type} = payload, socket) do
    dispatch(socket, payload)
  end

  def handle_in("answer", %{"ui_id" => ui_id} = payload, socket) do
    case decode_answer(payload) do
      {:ok, answer} ->
        case PiSession.answer(socket.assigns.session_id, ui_id, answer) do
          {:ok, _request} -> {:reply, :ok, socket}
          {:error, reason} -> {:reply, {:error, %{reason: to_string(reason)}}, socket}
        end

      :error ->
        {:reply, {:error, %{reason: "invalid_answer"}}, socket}
    end
  end

  def handle_in("pending_ui", _payload, socket) do
    case PiSession.pending_ui(socket.assigns.session_id) do
      {:ok, requests} -> {:reply, {:ok, %{pending_ui: requests}}, socket}
      {:error, reason} -> {:reply, {:error, %{reason: to_string(reason)}}, socket}
    end
  end

  def handle_in("close", _payload, socket) do
    :ok = PiSession.close(socket.assigns.session_id)
    {:stop, :normal, {:ok, %{closed: true}}, socket}
  end

  def handle_in(event, _payload, socket) do
    {:reply, {:error, %{reason: "unknown_event", event: event}}, socket}
  end

  # Runs the command outside the channel process so the channel stays live while
  # pi works. `:infinity` is deliberate: a command may park on a question, and
  # nothing on this side may decide the human took too long. The task ends
  # either way -- the session replies to every in-flight command when pi exits.
  defp dispatch(socket, payload) do
    session_id = socket.assigns.session_id
    ref = socket_ref(socket)

    Task.Supervisor.start_child(RintoPMOWeb.TaskSupervisor, fn ->
      case PiSession.command(session_id, payload, :infinity) do
        {:ok, response} -> reply(ref, {:ok, response})
        {:error, reason} -> reply(ref, {:error, %{reason: inspect(reason)}})
      end
    end)

    {:noreply, socket}
  end

  # The user's turn is written here rather than by
  # `RintoPMO.Conversations.Recorder`, because the refs that came with it are
  # known only at this point and a message without its refs cannot be replayed.
  # The raw text is stored, never `built.message` -- replay re-expands the refs
  # against the documents as they stand then, instead of feeding back a
  # snapshot from weeks ago.
  #
  # `actor_id` is what opts a prompt into being recorded. A session nobody
  # claimed is still perfectly usable; it simply is not a topic, and there is
  # no honest actor to attribute its turns to.
  defp record_prompt(%Conversation{} = conversation, message, refs, %{"actor_id" => actor_id})
       when is_binary(actor_id) do
    _result =
      conversations().append_message(conversation, %{
        actor_id: actor_id,
        role: :user,
        content: message,
        refs: refs
      })

    :ok
  end

  defp record_prompt(_conversation, _message, _refs, _payload), do: :ok

  # A session nobody claimed is still perfectly usable; it simply is not a
  # topic, so there is nothing to record against and nothing to replay.
  defp conversation_for(socket) do
    conversations().get_conversation_by_session(socket.assigns.session_id)
  end

  defp replay_for(nil), do: nil

  defp replay_for(%Conversation{} = conversation) do
    if conversations().claim_replay(conversation), do: conversation
  end

  # Strict unless a human has already been shown the list and said go ahead.
  defp on_missing_refs(%{"on_missing_refs" => "skip"}), do: :skip
  defp on_missing_refs(_payload), do: :fail

  defp conversations, do: RintoPMO.Utils.module(:conversations)

  # pi treats `images` as optional; sending an empty array would put an empty
  # content list in front of every text-only turn for no reason.
  defp put_images(command, []), do: command
  defp put_images(command, images), do: Map.put(command, "images", images)

  defp decode_answer(%{"value" => value}) when is_binary(value), do: {:ok, {:value, value}}

  defp decode_answer(%{"confirmed" => confirmed}) when is_boolean(confirmed),
    do: {:ok, {:confirmed, confirmed}}

  defp decode_answer(%{"cancelled" => true}), do: {:ok, :cancelled}
  defp decode_answer(_payload), do: :error
end
