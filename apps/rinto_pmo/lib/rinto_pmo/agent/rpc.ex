defmodule RintoPMO.Agent.Rpc do
  @moduledoc """
  Minimal client helpers for `pi --mode rpc` over stdio JSONL.

  Opens a short-lived pi process, sends one command after startup, reads the
  matching response, then shuts it down.

  Built on `RintoPMO.OSProcess`, which supplies the line framing, keeps pi a
  direct child with no shell to quote against, and guarantees the OS process is
  reaped even if this process dies mid-request.

  `OSProcess` is reached through `RintoPMO.Utils.module/1`, so a test of this
  module mocks it rather than spawning anything.
  """

  alias RintoPMO.OSProcess
  alias RintoPMO.Utils

  @enforce_keys [:os_process, :session_dir, :cleanup_session?]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          os_process: OSProcess.id(),
          session_dir: String.t(),
          cleanup_session?: boolean()
        }

  @type error ::
          :pi_not_found
          | :timeout
          | {:pi_exit, non_neg_integer()}
          | {:pi_died, OSProcess.exit_status()}
          | {:send_failed, OSProcess.call_error()}
          | {:spawn_failed, term()}
          | {:rpc_error, String.t()}
          | {:invalid_response, term()}

  defmodule Behaviour do
    @moduledoc """
    What a caller needs from an RPC round trip.

    Only `request/2`: `open/1`, `call/3` and `close/1` are the pieces it is
    built from, not something a caller drives directly.
    """

    alias RintoPMO.Agent.Rpc

    @callback request(map(), keyword()) :: {:ok, map()} | {:error, Rpc.error()}
  end

  @behaviour Behaviour

  # Long enough to absorb the trailing output of a pi that is shutting down,
  # short enough not to stall the caller.
  @leftover_timeout 200

  @doc """
  Runs one RPC command against a fresh `pi --mode rpc` process.

  Options:

    * `:executable` – pi binary (default configured `:pi_executable`)
    * `:timeout` – wall-clock timeout in ms (default 15_000)
    * `:offline` – pass `--offline` to pi
    * `:session_dir` – optional fixed session directory

  Commands are sent as soon as pi is spawned. pi has no readiness handshake and
  buffers whatever arrives before it is ready, so there is nothing to wait for.
  """
  @impl Behaviour
  @spec request(map(), keyword()) :: {:ok, map()} | {:error, error()}
  def request(command, opts \\ []) when is_map(command) do
    timeout = Keyword.get(opts, :timeout, 15_000)

    case open(opts) do
      {:ok, rpc} ->
        try do
          case call(rpc, command, timeout) do
            {:ok, response, rpc} ->
              close(rpc)
              {:ok, response}

            {:error, reason, rpc} ->
              close(rpc)
              {:error, reason}
          end
        catch
          kind, reason ->
            close(rpc)
            :erlang.raise(kind, reason, __STACKTRACE__)
        end

      {:error, _reason} = error ->
        error
    end
  end

  @doc false
  @spec open(keyword()) :: {:ok, t()} | {:error, :pi_not_found | {:spawn_failed, term()}}
  def open(opts \\ []) do
    executable = Keyword.get_lazy(opts, :executable, &pi_executable/0)
    {session_dir, cleanup?} = session_dir(opts)
    File.mkdir_p!(session_dir)

    # The id is settled up front so the instance stays addressable no matter how
    # quickly pi exits.
    id = "pi-rpc-#{System.unique_integer([:positive, :monotonic])}"

    start_opts = [
      id: id,
      cmd: executable,
      args: pi_args(session_dir, opts),
      owner: self(),
      framing: :lines,
      # Replaces the old `2>/dev/null` shell wrapper: pi's startup warnings and
      # the EPIPE it prints on close would otherwise be noise on discovery.
      stderr: :discard
    ]

    case os_process().start(start_opts) do
      {:ok, _pid} ->
        {:ok, %__MODULE__{os_process: id, session_dir: session_dir, cleanup_session?: cleanup?}}

      {:error, {:executable_not_found, _cmd}} ->
        cleanup_session(session_dir, cleanup?)
        {:error, :pi_not_found}

      {:error, reason} ->
        cleanup_session(session_dir, cleanup?)
        {:error, {:spawn_failed, reason}}
    end
  end

  @doc false
  @spec call(t(), map(), timeout()) :: {:ok, map(), t()} | {:error, error(), t()}
  def call(%__MODULE__{} = rpc, command, timeout \\ 10_000)
      when is_map(command) and is_integer(timeout) do
    command_id = command_id(command)
    payload = command |> stringify_keys() |> Map.put("id", command_id)

    case os_process().send(rpc.os_process, JSON.encode!(payload) <> "\n") do
      :ok ->
        await_response(rpc, command_id, System.monotonic_time(:millisecond) + timeout)

      {:error, reason} ->
        {:error, {:send_failed, reason}, rpc}
    end
  end

  @doc false
  @spec close(t()) :: :ok
  def close(%__MODULE__{} = rpc) do
    _ = os_process().stop(rpc.os_process)
    drain(rpc.os_process)
    cleanup_session(rpc.session_dir, rpc.cleanup_session?)
    :ok
  end

  # request/2 runs in the caller's process, which may well be a GenServer, so
  # anything pi emitted after the response has to be consumed here rather than
  # left to surface as an unexpected handle_info/2.
  defp drain(os_process) do
    receive do
      {:os_process, ^os_process, {:exit, _status}} -> :ok
      {:os_process, ^os_process, _event} -> drain(os_process)
    after
      @leftover_timeout -> :ok
    end
  end

  defp await_response(%__MODULE__{os_process: os_process} = rpc, command_id, deadline) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      {:error, :timeout, rpc}
    else
      receive do
        {:os_process, ^os_process, {:stdout, line}} ->
          case decode_response(line, command_id) do
            {:ok, response} -> {:ok, response, rpc}
            :continue -> await_response(rpc, command_id, deadline)
          end

        {:os_process, ^os_process, {:exit, status}} ->
          {:error, exit_error(status), rpc}
      after
        max(remaining, 1) -> {:error, :timeout, rpc}
      end
    end
  end

  # A clean exit code keeps the flat {:pi_exit, code} shape; a signal or a
  # teardown is a different kind of failure and says so.
  defp exit_error({:exit, code}), do: {:pi_exit, code}
  defp exit_error(status), do: {:pi_died, status}

  defp decode_response(line, command_id) do
    case JSON.decode(line) do
      {:ok, %{"type" => "response", "id" => ^command_id} = response} -> {:ok, response}
      _other -> :continue
    end
  end

  defp session_dir(opts) do
    case Keyword.fetch(opts, :session_dir) do
      {:ok, dir} when is_binary(dir) ->
        {dir, false}

      :error ->
        dir =
          Path.join(
            System.tmp_dir!(),
            "rinto-pmo-pi-rpc-#{System.unique_integer([:positive])}"
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

    if Keyword.get(opts, :offline, false), do: base ++ ["--offline"], else: base
  end

  defp command_id(command) do
    Map.get(command, "id") || Map.get(command, :id) ||
      "rpc-" <> Integer.to_string(System.unique_integer([:positive]))
  end

  defp os_process, do: Utils.module(:os_process)

  defp pi_executable do
    Application.get_env(:rinto_pmo, :pi_executable, "pi")
  end

  defp stringify_keys(map) do
    Map.new(map, fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), value}
      {key, value} when is_binary(key) -> {key, value}
    end)
  end
end
