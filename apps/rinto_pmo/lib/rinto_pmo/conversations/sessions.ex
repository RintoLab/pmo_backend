defmodule RintoPMO.Conversations.Sessions do
  @moduledoc """
  Decides which topics get a pi process.

  ## Hot and cold

  A conversation is **hot** when its `pi_session_id` names a live
  `RintoPMO.Agent.PiSession`, and **cold** otherwise. Cold is the resting
  state, not a failure: the messages are all still there, and they are enough
  to bring the topic back.

  One topic gets one pi process. A pi process holds a single conversation
  history, so running two topics through one would let them contaminate each
  other -- the concurrency pi's docs describe is concurrent *delivery* of
  commands, not isolated context.

  ## Why there is a limit at all

  Nothing else in the system stops a pi process from being started. Topics are
  cheap rows; pi processes are OS processes with a model connection each, and
  without a ceiling a busy afternoon opens dozens. So: **unlimited topics, a
  fixed number of processes**, with the least recently active evicted to make
  room. Eviction only cools a topic -- it never loses anything.

  A session with a question parked on it is never evicted. `pending_ui` has no
  timeout by design (see `RintoPMO.Agent.PiSession`), so that session is
  waiting on a specific human for a specific answer; closing it throws that
  question away and the human is never told.

  ## Reviving

  pi is started with `--no-session` and stores no history, so a revived topic
  starts with an empty process. The recent turns are handed back through a
  `conversation` reference on the next prompt (see
  `RintoPMO.Agent.PromptBuilder`), which re-expands the topic's own refs
  against the documents as they stand now rather than replaying a stale
  snapshot. `ensure_hot/2` reports which case happened so the caller knows
  whether that reference is needed.
  """

  alias RintoPMO.Agent.PiSession
  alias RintoPMO.Conversations.Conversation
  alias RintoPMO.Conversations.Recorder
  alias RintoPMO.Utils

  @type state :: :hot | :revived

  @type ensure_opt ::
          {:assistant_actor_id, UUIDv7.t()}
          | {:session_opts, keyword()}
          | {:pubsub, atom()}

  @doc """
  Returns whether a conversation currently has a live pi process.
  """
  @spec hot?(Conversation.t()) :: boolean()
  def hot?(%Conversation{pi_session_id: nil}), do: false
  def hot?(%Conversation{pi_session_id: session_id}), do: PiSession.alive?(session_id)

  @doc """
  Makes sure a conversation has a pi process, starting one if needed.

  Returns `{:ok, conversation, :hot}` when one was already running, and
  `{:ok, conversation, :revived}` when a new process was started -- in which
  case the caller should put a `conversation` reference on its next prompt so
  the model gets the recent turns back.

  Requires `:assistant_actor_id`: the AI actor that replies are attributed to.
  """
  @spec ensure_hot(Conversation.t(), [ensure_opt()]) ::
          {:ok, Conversation.t(), state()}
          | {:error, :session_limit_reached}
          | {:error, Ecto.Changeset.t()}
          | {:error, atom(), map()}
  def ensure_hot(%Conversation{} = conversation, opts) do
    if hot?(conversation) do
      {:ok, conversation, :hot}
    else
      revive(conversation, opts)
    end
  end

  @doc """
  Cools a conversation: closes its pi process and clears the pointer.

  The messages are untouched. This is what eviction does, and what closing a
  topic from the UI does.
  """
  @spec cool(Conversation.t()) :: {:ok, Conversation.t()} | {:error, Ecto.Changeset.t()}
  def cool(%Conversation{} = conversation) do
    if conversation.pi_session_id, do: PiSession.close(conversation.pi_session_id)
    Recorder.stop(conversation.id)
    conversations().detach_session(conversation)
  end

  @doc """
  The configured ceiling on simultaneously running pi processes.
  """
  @spec max_active_sessions() :: pos_integer()
  def max_active_sessions, do: setting(:max_active_sessions)

  @doc """
  Frees a session slot if the ceiling has been reached.

  Returns `{:ok, :evicted, info}` when a session was closed, `{:ok, :room}`
  when none was needed, and `{:error, :session_limit_reached}` when every
  running session is waiting on a human and so none may be taken.
  """
  @spec make_room() ::
          {:ok, :room} | {:ok, :evicted, PiSession.info()} | {:error, :session_limit_reached}
  def make_room do
    if PiSession.Supervisor.count() < max_active_sessions() do
      {:ok, :room}
    else
      evict_idlest()
    end
  end

  # `list_info/0` is already sorted most-idle-first, which is exactly the LRU
  # order wanted here.
  defp evict_idlest do
    PiSession.Supervisor.list_info()
    |> Enum.reject(& &1.awaiting_input?)
    |> case do
      [] ->
        {:error, :session_limit_reached}

      [idlest | _rest] ->
        cool_by_session(idlest.id)
        {:ok, :evicted, idlest}
    end
  end

  defp cool_by_session(session_id) do
    case conversations().get_conversation_by_session(session_id) do
      nil ->
        # A session nothing owns -- started outside this module. Close it
        # anyway; the slot is what matters.
        PiSession.close(session_id)

      %Conversation{} = conversation ->
        cool(conversation)
    end
  end

  defp revive(conversation, opts) do
    actor_id = Keyword.fetch!(opts, :assistant_actor_id)
    pubsub = Keyword.get(opts, :pubsub, RintoPMO.PubSub)

    with {:ok, _room} <- room(),
         {:ok, session_id} <- start_session(conversation, opts),
         {:ok, conversation} <- conversations().attach_session(conversation, session_id) do
      {:ok, _pid} =
        Recorder.Supervisor.start_recorder(
          conversation_id: conversation.id,
          session_id: session_id,
          actor_id: actor_id,
          pubsub: pubsub
        )

      {:ok, conversation, :revived}
    end
  end

  defp room do
    case make_room() do
      {:ok, :room} -> {:ok, :room}
      {:ok, :evicted, _info} -> {:ok, :room}
      {:error, reason} -> {:error, reason}
    end
  end

  # A fresh id per revival rather than reusing the old one: the previous pi
  # process is gone, and reusing its id would make a stale `pi_session_id`
  # elsewhere look live.
  defp start_session(conversation, opts) do
    session_id = "conversation-#{conversation.id}-#{System.unique_integer([:positive])}"
    session_opts = Keyword.get(opts, :session_opts, [])

    case PiSession.Supervisor.start_session(Keyword.put(session_opts, :id, session_id)) do
      {:ok, _pid} ->
        {:ok, session_id}

      {:error, {:already_started, _pid}} ->
        {:ok, session_id}

      # pi missing, or refusing to spawn. The reason is an arbitrary term, so
      # it is carried as diagnostic text under one code the caller can act on.
      {:error, reason} ->
        {:error, :agent_unavailable, %{reason: inspect(reason)}}
    end
  end

  defp conversations, do: Utils.module(:conversations)

  defp setting(key) do
    :rinto_pmo
    |> Application.fetch_env!(RintoPMO.Conversations)
    |> Keyword.fetch!(key)
  end
end
