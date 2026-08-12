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

  alias RintoPMO.Actors.Actor
  alias RintoPMO.Agent.PiSession
  alias RintoPMO.Conversations.Conversation
  alias RintoPMO.Conversations.Recorder
  alias RintoPMO.Utils

  @type state :: :hot | :revived

  @type ensure_opt :: {:session_opts, keyword()} | {:pubsub, atom()}

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
  case `replay_pending` is set, and the next prompt hands the recent turns to
  the empty process it found.

  Nobody is expected to call this deliberately. You cannot talk to a cold
  topic, so the topic somebody is talking to is hot by definition: heating is
  what sending a message does, not a step before it. This is why there is no
  endpoint for it.
  """
  @spec ensure_hot(Conversation.t(), [ensure_opt()]) ::
          {:ok, Conversation.t(), state()}
          | {:error, :session_limit_reached}
          | {:error, :assistant_actor_required}
          | {:error, Ecto.Changeset.t()}
          | {:error, atom(), map()}
  def ensure_hot(%Conversation{} = conversation, opts \\ []) do
    cond do
      hot?(conversation) -> {:ok, conversation, :hot}
      is_nil(conversation.assistant_actor_id) -> {:error, :assistant_actor_required}
      true -> revive(conversation, opts)
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
  Changes which AI a topic is talking to, and cools it so the change lands.

  A pi process reads which model to be, and its system prompt, once at startup:
  it runs `--no-session`, so there is nothing to reconfigure afterwards. Writing
  the new actor onto the row without closing the process would leave a topic
  answering as the old one until it happened to be evicted -- exactly the kind of
  silent gap this call exists to close.

  **The conversation survives the switch.** History lives here rather than in pi,
  and cooling arms the replay, so the first prompt after this hands the new model
  the recent turns. It reads what was said before it arrived.

  What does not move is attribution: turns already recorded keep the actor that
  said them, and only turns from here on are credited to the new one. "Which
  model wrote this paragraph" stays answerable.
  """
  @spec switch_assistant(Conversation.t(), UUIDv7.t()) ::
          {:ok, Conversation.t()} | {:error, Ecto.Changeset.t()}
  def switch_assistant(%Conversation{} = conversation, actor_id) do
    with {:ok, conversation} <-
           conversations().update_conversation(conversation, %{assistant_actor_id: actor_id}) do
      cool(conversation)
    end
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
    actor_id = conversation.assistant_actor_id
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

    # The caller's own options win: a test injects its fake pi this way, and it
    # is not asking for the assistant's model when it does.
    session_opts =
      conversation
      |> persona_opts()
      |> Keyword.merge(Keyword.get(opts, :session_opts, []))
      |> Keyword.put(:id, session_id)

    case PiSession.Supervisor.start_session(session_opts) do
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

  # The assistant actor's configuration, translated into what a session needs.
  # `ensure_hot/2` has already refused a conversation with no assistant, so the
  # empty case here is a row that has gone or one whose kind says it cannot
  # answer -- both of which fall back to pi's defaults rather than failing a
  # revive, because a topic that cannot be opened is worse than one answering as
  # a default model.
  defp persona_opts(%Conversation{assistant_actor_id: nil}), do: []

  defp persona_opts(%Conversation{assistant_actor_id: actor_id}) do
    case actors().get_actor!(actor_id) do
      %Actor{kind: :ai} = actor ->
        [
          provider: actor.provider,
          model: actor.model,
          thinking: actor.thinking_level,
          system_prompt: actor.system_prompt
        ]

      %Actor{} ->
        []
    end
  rescue
    Ecto.NoResultsError -> []
  end

  defp actors, do: Utils.module(:actors)

  defp conversations, do: Utils.module(:conversations)

  defp setting(key) do
    :rinto_pmo
    |> Application.fetch_env!(RintoPMO.Conversations)
    |> Keyword.fetch!(key)
  end
end
