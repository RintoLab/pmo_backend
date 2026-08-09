defmodule RintoPMOWeb.ConversationChannel do
  @moduledoc """
  A topic, as the client talks to it.

  ## Addressed by conversation, not by agent process

      socket.channel("conversation:" + conversationId, {})

  Whether a pi process is currently carrying the topic is an implementation
  detail and is kept out of the client's way entirely. **You cannot talk to a
  cold topic, so the topic you are talking to is hot by definition**: the first
  `"prompt"` starts a process if there is not one, and there is no endpoint to
  do it in advance. Joining alone starts nothing -- opening a panel to read
  should not cost a process.

  Addressing by conversation also means the channel outlives the process. When
  pi exits, an `"exit"` is pushed and the channel stays joined; the next prompt
  starts a new process and the client never learns that anything was replaced.
  Addressing by session id could not do that -- the client would have to go
  find the new id before it could reconnect.

  ## Joining

  A join immediately pushes the topic's current state, so a client arriving
  long after a question was asked still sees it:

      {"pending_ui": [request, ...]}

  Leaving does not cool the topic. That is the explicit `"close"` message, or
  `POST /conversations/{id}/close`.

  ## Client to server

    * `"prompt"` -- `%{"message" => "..."}`, the ordinary way to talk to the
      agent; optional `"refs"` name things in this system to put in front of
      the message (see `RintoPMO.Agent.PromptBuilder`), `"actor_id"` records
      the turn as the human's, `"on_missing_refs"` may be `"skip"` once a
      person has been shown what is gone and chosen to go ahead, and
      `"images"` / `"streamingBehavior"` pass straight through
    * `"command"` -- `%{"type" => "get_state", ...}`, any raw RPC command;
      requires a running process, and will not start one
    * `"answer"` -- `%{"ui_id" => id, "value" | "confirmed" | "cancelled" => _}`
    * `"pending_ui"` -- re-read the parked questions
    * `"close"` -- cool the topic; every message it holds stays

  A `"prompt"` carrying a reference that cannot be resolved is refused rather
  than sent with the reference silently dropped -- `{"reason":
  "ref_not_found"}` lists every one that is gone, `{"reason": "invalid_ref"}`
  means the client built one wrong. Half a question is worse than none: the
  agent would answer confidently about a document it never saw.

  ## Server to client

    * `"event"` -- a conversation frame (`message_update`, `turn_end`, ...)
    * `"ui_request"` -- the agent is waiting on a human
    * `"ui_resolved"` -- `%{"ui_id" => id}`, that question is answered
    * `"conversation_updated"` -- `%{"data" => conversation}`, the topic's own
      row changed. Today that means it has just been named (see
      `RintoPMO.Conversations.Titles`), which happens in the background and may
      well land after the answer to the message that triggered it. The payload
      is the same shape `GET /conversations/{id}` returns, so a client renders
      it the same way
    * `"exit"` -- the agent process ended. The channel stays; prompt again to
      start a new one

  `"conversation_updated"` goes to everyone joined to the topic, not to the
  connection that prompted: a title arriving has to reach the other tab, and
  the list beside it.
  """

  use RintoPMOWeb, :channel

  alias RintoPMO.Agent.PiSession
  alias RintoPMO.Agent.PromptBuilder
  alias RintoPMO.Conversations.Conversation
  alias RintoPMO.Conversations.Notifier
  alias RintoPMO.Conversations.Sessions
  alias RintoPMO.Utils
  alias RintoPMOWeb.V1.ConversationJSON

  @impl true
  def join("conversation:" <> conversation_id, _params, socket) do
    case fetch_conversation(conversation_id) do
      {:ok, conversation} ->
        send(self(), :after_join)
        {:ok, assign(socket, conversation: conversation, session_id: nil)}

      :error ->
        {:error, %{reason: "not_found"}}
    end
  end

  @impl true
  def handle_info(:after_join, socket) do
    # Subscribed for as long as the channel is joined, and independently of any
    # pi session: the row can change while the topic is cold, and a client
    # reading a cold topic still wants to see it named.
    :ok = Notifier.subscribe(socket.assigns.conversation.id)

    socket = follow_session(socket, socket.assigns.conversation.pi_session_id)
    push(socket, "pending_ui", %{pending_ui: pending_ui(socket)})
    {:noreply, socket}
  end

  # Only the naming columns are taken from the broadcast. The rest of that row
  # is a snapshot from whenever the writer read it, while this channel has
  # watched the session it holds come and go.
  def handle_info({:conversation_updated, updated}, socket) do
    conversation = %{
      socket.assigns.conversation
      | title: updated.title,
        title_source: updated.title_source,
        title_generated_at: updated.title_generated_at
    }

    socket = assign(socket, :conversation, conversation)
    push(socket, "conversation_updated", %{data: ConversationJSON.data(conversation)})
    {:noreply, socket}
  end

  def handle_info({:pi_session, id, {:event, frame}}, %{assigns: %{session_id: id}} = socket) do
    push(socket, "event", frame)
    {:noreply, socket}
  end

  def handle_info(
        {:pi_session, id, {:ui_request, request}},
        %{assigns: %{session_id: id}} = socket
      ) do
    push(socket, "ui_request", request)
    {:noreply, socket}
  end

  def handle_info(
        {:pi_session, id, {:ui_resolved, ui_id}},
        %{assigns: %{session_id: id}} = socket
      ) do
    push(socket, "ui_resolved", %{ui_id: ui_id})
    {:noreply, socket}
  end

  # The process is gone, the topic is not. Staying joined is the point of
  # addressing this channel by conversation: the next prompt starts a new
  # process and the client never has to learn a new address.
  def handle_info({:pi_session, id, {:exit, status}}, %{assigns: %{session_id: id}} = socket) do
    push(socket, "exit", %{status: inspect(status)})

    # The pointer is cleared here too, not just the subscription. The session
    # announces its exit while it is still unwinding, so for a moment longer
    # `Sessions.hot?/1` would still say yes and hand back a process that is on
    # its way out. Having watched it go is better evidence than asking.
    conversation = %{socket.assigns.conversation | pi_session_id: nil}

    {:noreply, socket |> assign(:conversation, conversation) |> unfollow_session()}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  # `message` rather than `text`: pi's own `prompt` command names it that way
  # (`RpcCommand` in its `rpc-types.d.ts`), and matching its vocabulary keeps
  # this API readable against pi's protocol docs.
  @impl true
  def handle_in("prompt", %{"message" => message} = payload, socket) do
    refs = Map.get(payload, "refs", [])

    with {:ok, socket} <- ensure_hot(socket),
         {:ok, built} <- build(socket, message, refs, payload) do
      # Written before the command goes out, so the human's turn is at a lower
      # position than the reply the recorder writes for it. The replay is
      # deliberately not among the refs recorded: the system restored that
      # context, the human did not cite it.
      record_prompt(socket, message, refs, payload)

      command =
        payload
        |> Map.take(["streamingBehavior"])
        |> Map.merge(%{"type" => "prompt", "message" => built.message})
        |> put_images(built.images ++ Map.get(payload, "images", []))

      dispatch(socket, command)
    else
      {:error, reason} ->
        {:reply, {:error, %{reason: to_string(reason)}}, socket}

      {:error, reason, details} ->
        {:reply, {:error, %{reason: to_string(reason), details: details}}, socket}
    end
  end

  # Raw commands do not start a process. They are an escape hatch onto a
  # running agent, and `get_state` is no reason to spend a session slot.
  def handle_in("command", %{"type" => _type} = payload, socket) do
    if socket.assigns.session_id, do: dispatch(socket, payload), else: cold(socket)
  end

  def handle_in("answer", %{"ui_id" => ui_id} = payload, socket) do
    with {:ok, session_id} <- running(socket),
         {:ok, answer} <- decode_answer(payload),
         {:ok, _request} <- PiSession.answer(session_id, ui_id, answer) do
      {:reply, :ok, socket}
    else
      :error -> {:reply, {:error, %{reason: "invalid_answer"}}, socket}
      {:error, reason} -> {:reply, {:error, %{reason: to_string(reason)}}, socket}
    end
  end

  # A cold topic has no parked questions, which is an answer rather than an
  # error: whatever was being asked went with the process.
  def handle_in("pending_ui", _payload, socket) do
    {:reply, {:ok, %{pending_ui: pending_ui(socket)}}, socket}
  end

  def handle_in("close", _payload, socket) do
    case Sessions.cool(socket.assigns.conversation) do
      {:ok, conversation} ->
        socket = socket |> unfollow_session() |> assign(:conversation, conversation)
        {:reply, {:ok, %{closed: true}}, socket}

      {:error, _changeset} ->
        {:reply, {:error, %{reason: "close_failed"}}, socket}
    end
  end

  def handle_in(event, _payload, socket) do
    {:reply, {:error, %{reason: "unknown_event", event: event}}, socket}
  end

  # Heating

  # The subscription is resynchronised on both outcomes, not just on a revive.
  # `:hot` does not imply the channel is still following that session -- an
  # exit seen a moment earlier will have dropped it.
  defp ensure_hot(socket) do
    case Sessions.ensure_hot(socket.assigns.conversation) do
      {:ok, conversation, _state} ->
        socket =
          socket
          |> assign(:conversation, conversation)
          |> follow_session(conversation.pi_session_id)

        {:ok, socket}

      {:error, _reason} = error ->
        error

      {:error, _code, _details} = error ->
        error
    end
  end

  # Subscribing explicitly, because the channel topic is the conversation and
  # no longer happens to equal the session's. Following one session at a time
  # keeps a stale subscription from pushing a dead process's frames.
  defp follow_session(%{assigns: %{session_id: session_id}} = socket, session_id), do: socket
  defp follow_session(socket, nil), do: unfollow_session(socket)

  defp follow_session(socket, session_id) do
    socket = unfollow_session(socket)
    :ok = PiSession.subscribe(session_id)
    assign(socket, :session_id, session_id)
  end

  defp unfollow_session(%{assigns: %{session_id: nil}} = socket), do: socket

  defp unfollow_session(socket) do
    Phoenix.PubSub.unsubscribe(RintoPMO.PubSub, PiSession.topic(socket.assigns.session_id))
    assign(socket, :session_id, nil)
  end

  defp running(socket) do
    case socket.assigns.session_id do
      nil -> {:error, :not_running}
      session_id -> {:ok, session_id}
    end
  end

  defp cold(socket), do: {:reply, {:error, %{reason: "not_running"}}, socket}

  defp pending_ui(socket) do
    with {:ok, session_id} <- running(socket),
         {:ok, requests} <- PiSession.pending_ui(session_id) do
      requests
    else
      _cold_or_gone -> []
    end
  end

  # Prompting

  defp build(socket, message, refs, payload) do
    PromptBuilder.build(message, refs,
      replay: replay_for(socket.assigns.conversation),
      on_missing_refs: on_missing_refs(payload)
    )
  end

  # Only the first prompt after a revive carries the history, and the claim is
  # atomic so two tabs cannot both pay it.
  defp replay_for(%Conversation{} = conversation) do
    if conversations().claim_replay(conversation), do: conversation
  end

  # Strict unless a human has already been shown the list and said go ahead.
  defp on_missing_refs(%{"on_missing_refs" => "skip"}), do: :skip
  defp on_missing_refs(_payload), do: :fail

  # The refs that came with a prompt are known only here, and a message without
  # its refs cannot be replayed. The raw text is stored, never the expanded
  # one -- replay re-expands against the documents as they stand then.
  #
  # `actor_id` is what opts a prompt into being recorded: without one there is
  # nobody to attribute the turn to.
  defp record_prompt(socket, message, refs, %{"actor_id" => actor_id})
       when is_binary(actor_id) do
    _result =
      conversations().append_message(socket.assigns.conversation, %{
        actor_id: actor_id,
        role: :user,
        content: message,
        refs: refs
      })

    :ok
  end

  defp record_prompt(_socket, _message, _refs, _payload), do: :ok

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

  # pi treats `images` as optional; sending an empty array would put an empty
  # content list in front of every text-only turn for no reason.
  defp put_images(command, []), do: command
  defp put_images(command, images), do: Map.put(command, "images", images)

  defp decode_answer(%{"value" => value}) when is_binary(value), do: {:ok, {:value, value}}

  defp decode_answer(%{"confirmed" => confirmed}) when is_boolean(confirmed),
    do: {:ok, {:confirmed, confirmed}}

  defp decode_answer(%{"cancelled" => true}), do: {:ok, :cancelled}
  defp decode_answer(_payload), do: :error

  defp fetch_conversation(conversation_id) do
    {:ok, conversations().get_conversation!(conversation_id)}
  rescue
    _missing_or_malformed -> :error
  end

  defp conversations, do: Utils.module(:conversations)
end
