defmodule RintoPMO.Agent.PiSession do
  @moduledoc """
  A long-lived `pi --mode rpc` conversation.

  Unlike `RintoPMO.Agent.Rpc`, which opens a process per request, a session
  outlives individual commands. That is what makes it possible to park on a
  question and resume when a human answers, however long that takes.

  ## Commands

  `command/3` sends one command and blocks until its response arrives, matched
  by `id`. pi dispatches input lines without awaiting them
  (`void handleInputLine(line)` in its `rpc-mode.js`), so commands are handled
  concurrently and responses may arrive out of order -- correlation by `id` is
  required, not merely convenient.

  ## Suspension

  Extensions can ask a question through pi's UI channel. Four methods block the
  extension until answered: `select`, `confirm`, `input` and `editor`. There is
  no timeout unless the extension supplies one, and `editor` cannot carry one at
  all, so an unanswered question waits forever by design.

  This module leans into that: a blocking request is parked in `pending_ui/1`
  and broadcast, and nothing expires it. Answering is `answer/3`. Callers that
  have no human to ask should answer `:cancelled` immediately -- pi's own
  handlers treat that as a decline and carry on.

  Because pi reads input without awaiting command handling, an
  `extension_ui_response` is still read while a command sits parked on a dialog.
  A question therefore never deadlocks the session.

  ## Events

  Subscribe with `subscribe/1` to receive, for `session_id`:

      {:pi_session, session_id, {:ui_request, request}}
      {:pi_session, session_id, {:ui_resolved, ui_id}}
      {:pi_session, session_id, {:event, frame}}
      {:pi_session, session_id, {:exit, exit_status}}

  `:event` carries conversation frames only -- `message_start`,
  `message_update`, `message_end`, `turn_start`, `turn_end`, named in
  `RintoPMO.Agent.Events`. Everything else pi emits (status bars, widgets,
  unknown future frame types) is dropped, so new pi releases and newly
  installed extensions cannot break a consumer.

  ## Lifecycle

  Sessions are `:temporary`: a crash is not retried, because pi's own state --
  including any parked question -- lives in that OS process and is gone with it.
  Nothing expires an idle session, so whoever starts one owns ending it with
  `close/1`.
  """

  use GenServer

  alias RintoPMO.Agent.Events
  alias RintoPMO.OSProcess

  @registry __MODULE__.Registry

  @blocking_ui_methods ~w(select confirm input editor)

  @default_command_timeout 30_000

  @type id :: String.t()
  @type session :: id() | pid()

  @typedoc """
  An operational snapshot of one session.

  `idle_ms` is time since pi last said anything or was last spoken to, which is
  how an abandoned session is spotted: nothing expires one on its own.
  """
  @type info :: %{
          id: id(),
          pid: pid(),
          os_pid: pos_integer() | nil,
          started_at: DateTime.t(),
          idle_ms: non_neg_integer(),
          awaiting_input?: boolean(),
          pending_ui: [map()],
          in_flight_commands: non_neg_integer()
        }

  @typedoc """
  A reply to a parked question.

  `{:value, v}` answers `select` (with one of the offered `options`), `input` or
  `editor`; `{:confirmed, bool}` answers `confirm`; `:cancelled` declines any of
  them.
  """
  @type answer :: {:value, String.t()} | {:confirmed, boolean()} | :cancelled

  @type start_opt ::
          {:id, id()}
          | {:executable, String.t()}
          | {:session_dir, Path.t()}
          | {:offline, boolean()}
          | {:extra_args, [String.t()]}
          | {:pubsub, atom()}
          | {:provider, String.t() | nil}
          | {:model, String.t() | nil}
          | {:thinking, String.t() | nil}
          | {:system_prompt, String.t() | nil}
          | {:env, [{String.t(), String.t()}]}

  # Public API

  @doc """
  Starts a session. Prefer `RintoPMO.Agent.PiSession.Supervisor.start_session/1`.
  """
  @spec start_link([start_opt()]) :: GenServer.on_start()
  def start_link(opts) do
    id = Keyword.get_lazy(opts, :id, &generate_id/0)
    GenServer.start_link(__MODULE__, {id, opts}, name: via(id))
  end

  @doc false
  def child_spec(opts) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}, restart: :temporary}
  end

  @doc """
  Sends a command and waits for the response matching its `id`.

  An `"id"` already present in `payload` is kept, so a caller can choose its own
  correlation key.
  """
  @spec command(session(), map(), timeout()) ::
          {:ok, map()} | {:error, :not_found | :timeout | term()}
  def command(session, payload, timeout \\ @default_command_timeout) when is_map(payload) do
    call(session, {:command, payload}, timeout)
  end

  @doc """
  Lists questions currently waiting on a human, newest last.
  """
  @spec pending_ui(session()) :: {:ok, [map()]} | {:error, :not_found}
  def pending_ui(session), do: call(session, :pending_ui, 5_000)

  @doc """
  Returns an operational snapshot of a session.

  Always answers promptly: commands are tracked rather than awaited, so an
  in-flight prompt -- even one parked on a question -- never delays this.
  """
  @spec info(session()) :: {:ok, info()} | {:error, :not_found | :timeout}
  def info(session), do: call(session, :info, 5_000)

  @doc """
  Answers a parked question, releasing whatever is blocked on it.
  """
  @spec answer(session(), String.t(), answer()) ::
          {:ok, map()} | {:error, :not_found | :unknown_ui_request | term()}
  def answer(session, ui_id, answer) when is_binary(ui_id) do
    call(session, {:answer, ui_id, answer}, 5_000)
  end

  @doc """
  Stops the session and its pi process.
  """
  @spec close(session()) :: :ok
  def close(session) do
    case resolve(session) do
      {:ok, pid} -> GenServer.stop(pid, :normal, 15_000)
      :error -> :ok
    end
  catch
    :exit, _reason -> :ok
  end

  @doc """
  Subscribes the calling process to a session's events.
  """
  @spec subscribe(id(), atom()) :: :ok | {:error, term()}
  def subscribe(session_id, pubsub \\ RintoPMO.PubSub),
    do: Phoenix.PubSub.subscribe(pubsub, topic(session_id))

  @doc """
  The PubSub topic a session publishes on.
  """
  @spec topic(id()) :: String.t()
  def topic(session_id), do: "pi_session:#{session_id}"

  @doc """
  Returns whether a session is running.
  """
  # The registry unregisters on the monitor's DOWN, which lands after the
  # process is already gone. Checking the pid too closes the window in which a
  # stale entry would report a dead session as alive.
  @spec alive?(session()) :: boolean()
  def alive?(pid) when is_pid(pid), do: Process.alive?(pid)

  def alive?(id) when is_binary(id) do
    case resolve(id) do
      {:ok, pid} -> Process.alive?(pid)
      :error -> false
    end
  end

  # GenServer

  @impl true
  def init({id, opts}) do
    Process.flag(:trap_exit, true)

    {session_dir, cleanup?} = session_dir(opts)
    File.mkdir_p!(session_dir)

    start_opts = [
      id: "pi-session-#{id}",
      cmd: Keyword.get_lazy(opts, :executable, &pi_executable/0),
      args: pi_args(session_dir, opts),
      # Passed through without inspection: what a tool pi runs needs to find in
      # its environment is the caller's business, not this module's. It speaks
      # pi's command line; it has no opinion about the rest of the system.
      env: Keyword.get(opts, :env, []),
      owner: self(),
      framing: :lines,
      stderr: :discard
    ]

    case OSProcess.start(start_opts) do
      {:ok, _pid} ->
        {:ok,
         %{
           id: id,
           os_process: start_opts[:id],
           pending_commands: %{},
           pending_ui: %{},
           session_dir: session_dir,
           cleanup_session?: cleanup?,
           pubsub: Keyword.get(opts, :pubsub, RintoPMO.PubSub),
           started_at: DateTime.utc_now(),
           # Monotonic, so a clock adjustment cannot make a session look idle.
           last_activity: System.monotonic_time(:millisecond)
         }}

      {:error, {:executable_not_found, _cmd}} ->
        cleanup_session(session_dir, cleanup?)
        {:stop, :pi_not_found}

      {:error, reason} ->
        cleanup_session(session_dir, cleanup?)
        {:stop, {:spawn_failed, reason}}
    end
  end

  @impl true
  def handle_call({:command, payload}, from, state) do
    command_id = command_id(payload)
    frame = payload |> stringify_keys() |> Map.put("id", command_id)

    case OSProcess.send(state.os_process, JSON.encode!(frame) <> "\n") do
      :ok -> {:noreply, touch(put_in(state.pending_commands[command_id], from))}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:pending_ui, _from, state) do
    {:reply, {:ok, Map.values(state.pending_ui)}, state}
  end

  def handle_call(:info, _from, state) do
    {:reply, {:ok, snapshot(state)}, state}
  end

  def handle_call({:answer, ui_id, answer}, _from, state) do
    case pop_in(state.pending_ui[ui_id]) do
      {nil, _state} ->
        {:reply, {:error, :unknown_ui_request}, state}

      {request, state} ->
        payload = Map.merge(%{"type" => "extension_ui_response", "id" => ui_id}, encode(answer))

        case OSProcess.send(state.os_process, JSON.encode!(payload) <> "\n") do
          :ok ->
            broadcast(state, {:ui_resolved, ui_id})
            {:reply, {:ok, request}, state}

          {:error, reason} ->
            {:reply, {:error, reason}, put_in(state.pending_ui[ui_id], request)}
        end
    end
  end

  @impl true
  def handle_info({:os_process, os_process, {:stdout, line}}, %{os_process: os_process} = state) do
    {:noreply, touch(handle_frame(JSON.decode(line), state))}
  end

  def handle_info({:os_process, os_process, {:exit, status}}, %{os_process: os_process} = state) do
    broadcast(state, {:exit, status})

    for {_id, from} <- state.pending_commands,
        do: GenServer.reply(from, {:error, {:exit, status}})

    {:stop, :normal, %{state | pending_commands: %{}}}
  end

  def handle_info(_message, state), do: {:noreply, state}

  # Stopping the instance explicitly rather than relying on the owner-DOWN path
  # makes the reap synchronous, so `close/1` returning means the pi process is
  # actually gone. Leaving it to the monitor would return first and reap later.
  @impl true
  def terminate(_reason, state) do
    _ = OSProcess.stop(state.os_process)
    cleanup_session(state.session_dir, state.cleanup_session?)
    :ok
  end

  # Frame handling
  #
  # Positive matching only. Anything unrecognised -- a status bar update, a
  # widget, a frame type a future pi adds -- falls through to :ignore, so this
  # never needs updating when pi or an extension grows a new message.

  defp handle_frame({:ok, %{"type" => "response", "id" => id} = frame}, state)
       when is_map_key(state.pending_commands, id) do
    {from, state} = pop_in(state.pending_commands[id])
    GenServer.reply(from, {:ok, frame})
    state
  end

  defp handle_frame({:ok, %{"type" => "extension_ui_request", "method" => method} = frame}, state)
       when method in @blocking_ui_methods do
    ui_id = frame["id"]
    broadcast(state, {:ui_request, frame})
    put_in(state.pending_ui[ui_id], frame)
  end

  defp handle_frame({:ok, frame}, state) do
    if Events.conversation?(frame), do: broadcast(state, {:event, frame})
    state
  end

  defp handle_frame(_other, state), do: state

  # Helpers

  defp touch(state), do: %{state | last_activity: System.monotonic_time(:millisecond)}

  defp snapshot(state) do
    %{
      id: state.id,
      pid: self(),
      os_pid: os_pid(state.os_process),
      started_at: state.started_at,
      idle_ms: System.monotonic_time(:millisecond) - state.last_activity,
      awaiting_input?: state.pending_ui != %{},
      pending_ui: Map.values(state.pending_ui),
      in_flight_commands: map_size(state.pending_commands)
    }
  end

  # nil rather than an error: the instance can be gone while this process is
  # still winding down, and a snapshot should still describe what it can.
  defp os_pid(os_process) do
    case OSProcess.info(os_process) do
      {:ok, %{os_pid: os_pid}} -> os_pid
      {:error, _reason} -> nil
    end
  end

  defp encode({:value, value}) when is_binary(value), do: %{"value" => value}

  defp encode({:confirmed, confirmed?}) when is_boolean(confirmed?),
    do: %{"confirmed" => confirmed?}

  defp encode(:cancelled), do: %{"cancelled" => true}

  defp broadcast(state, event) do
    Phoenix.PubSub.broadcast(state.pubsub, topic(state.id), {:pi_session, state.id, event})
  end

  defp via(id), do: {:via, Registry, {@registry, id}}

  defp resolve(pid) when is_pid(pid), do: {:ok, pid}

  defp resolve(id) when is_binary(id) do
    case Registry.lookup(@registry, id) do
      [{pid, _value}] -> {:ok, pid}
      [] -> :error
    end
  end

  defp call(session, request, timeout) do
    case resolve(session) do
      {:ok, pid} -> GenServer.call(pid, request, timeout)
      :error -> {:error, :not_found}
    end
  catch
    :exit, {reason, _call} when reason in [:noproc, :normal, :shutdown] -> {:error, :not_found}
    :exit, {:timeout, _call} -> {:error, :timeout}
    :exit, reason -> {:error, {:call_failed, reason}}
  end

  defp command_id(payload) do
    Map.get(payload, "id") || Map.get(payload, :id) ||
      "cmd-" <> Integer.to_string(System.unique_integer([:positive, :monotonic]))
  end

  defp generate_id, do: "pi-#{System.unique_integer([:positive, :monotonic])}"

  defp session_dir(opts) do
    case Keyword.fetch(opts, :session_dir) do
      {:ok, dir} when is_binary(dir) ->
        {dir, false}

      :error ->
        dir =
          Path.join(
            System.tmp_dir!(),
            "rinto-pmo-pi-session-#{System.unique_integer([:positive])}"
          )

        {dir, true}
    end
  end

  defp cleanup_session(_dir, false), do: :ok

  defp cleanup_session(dir, true) do
    _ = File.rm_rf(dir)
    :ok
  end

  defp pi_args(session_dir, opts) do
    base = ["--mode", "rpc", "--no-session", "--session-dir", session_dir]
    base = if Keyword.get(opts, :offline, false), do: base ++ ["--offline"], else: base

    # Ahead of `extra_args`, which has to stay last: it is how a test hands the
    # fake pi its behaviour file, and the fake reads its *last* argument.
    base ++ persona_args(opts) ++ Keyword.get(opts, :extra_args, [])
  end

  # Which model answers, and as whom. Absent options are simply not passed, and
  # pi falls back to its own defaults. Conversation code normally supplies
  # either a fixed actor's configuration or a plain chat's inline selection.
  defp persona_args(opts) do
    model_args(opts) ++
      flag(opts, :thinking, "--thinking") ++
      flag(opts, :system_prompt, "--system-prompt")
  end

  # A provider without a model names nothing pi can act on, so the pair travels
  # together or not at all.
  defp model_args(opts) do
    case {value(opts, :provider), value(opts, :model)} do
      {provider, model} when is_binary(provider) and is_binary(model) ->
        ["--provider", provider, "--model", model]

      {_provider, model} when is_binary(model) ->
        ["--model", model]

      _neither ->
        []
    end
  end

  defp flag(opts, key, name) do
    case value(opts, key) do
      nil -> []
      value -> [name, value]
    end
  end

  defp value(opts, key) do
    case Keyword.get(opts, key) do
      value when is_binary(value) and value != "" -> value
      _absent_or_blank -> nil
    end
  end

  defp pi_executable, do: Application.get_env(:rinto_pmo, :pi_executable, "pi")

  defp stringify_keys(map) do
    Map.new(map, fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), value}
      {key, value} when is_binary(key) -> {key, value}
    end)
  end
end
