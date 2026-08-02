defmodule RintoPMO.OSProcess do
  @moduledoc """
  Start, write to, read from, and stop external OS processes.

  Backed by [erlexec](https://github.com/saleyn/erlexec). Domain-agnostic: it
  moves bytes and knows nothing about whatever protocol the child speaks.

  Each instance is addressed by an arbitrary caller-supplied `t:id/0`, which is
  never interpreted here. Many instances run concurrently.

  ## Usage

  Long-running and interactive children are started, written to, and stopped:

      {:ok, _pid} = RintoPMO.OSProcess.start(id: "echo-1", cmd: "cat", framing: :lines)
      :ok = RintoPMO.OSProcess.send("echo-1", "hello\\n")
      # the owner receives {:os_process, "echo-1", {:stdout, "hello"}}
      :ok = RintoPMO.OSProcess.stop("echo-1")

  A one-shot command that just needs its output is a single blocking call:

      {:ok, %{status: {:exit, 0}, stdout: "hi\\n"}} =
        RintoPMO.OSProcess.run(cmd: "echo", args: ["hi"])

  ## Addressing

  Every function accepts either the caller-supplied `t:id/0` or the pid returned
  by `start/1`. `:id` is optional -- omit it and one is generated, which suits
  callers that keep the pid and never need a name.

  ## Messages to the owner

  The `:owner` (the caller of `start/1` unless overridden) receives:

      {:os_process, id, {:stdout, binary}}
      {:os_process, id, {:stderr, binary}}
      {:os_process, id, {:exit, exit_status}}

  Exactly one `{:exit, _}` is delivered per instance, and nothing for that id
  afterwards. The tag does not change with `:framing` -- only the payload does
  (a raw chunk versus one complete line).

  The exit event reports how the instance ended, which is not always how the
  child ended. A child that ran to completion yields `{:exit, code}` or
  `{:signal, _, _}`; an instance torn down by `stop/2`, by a supervisor, or by
  its owner dying yields `{:stopped, reason}` -- the child was killed before it
  had a status of its own. The one case with no event at all is
  `Process.exit(pid, :kill)` on the instance, where `terminate/2` never runs.

  There is a single owner, not a subscriber list. A caller needing fan-out
  designates a long-lived process of its own as `:owner` and re-broadcasts.

  ## Streaming and child-side buffering

  Output is delivered as the child writes it -- erlexec never batches, and
  `framing: :lines` emits each line as it completes rather than waiting for the
  child to exit.

  What does batch is the child's own C library. `stdout` connected to a pipe is
  block-buffered (4-8 KB) instead of line-buffered, so a child using stdio
  without flushing explicitly appears to emit nothing until it exits, however
  long it runs. That is a property of the child, not of this module. The fix
  belongs on the child's side -- `python -u`, `stdbuf -oL`, or whatever the
  program offers -- because the alternative, allocating a pty so the child
  believes it is on a terminal, forces stdout and stderr onto one fd and makes
  `stderr: :owner` impossible.

  ## No shell

  `:cmd` and `:args` always become a direct `execve`. Nothing is passed through
  a shell, so quoting and injection are non-issues. A caller that wants a shell
  asks for one explicitly:

      start(id: id, cmd: "/bin/sh", args: ["-c", script])

  ## Orphan safety

  erlexec is asked to `:link` the OS process to the instance, so the OS process
  is reaped whenever the instance goes away -- including under
  `Process.exit(pid, :kill)`, where `terminate/2` never runs. The guarantee
  lives in that link, not in our cleanup code; `terminate/2` only makes the
  graceful path deterministic by waiting for the reap.

  ## Limits

  Every child's output is funnelled through erlexec's single `exec` gen_server,
  and `send/2` ultimately becomes a `GenServer.call` into it. That is fine at
  tens of concurrent instances with moderate output; a chatty child at hundreds
  of instances makes that server a shared bottleneck.

  There is no backpressure: output is pushed into the owner's mailbox as fast as
  the child writes. Owners holding many instances must drain promptly. Under
  `framing: :lines` a child that never emits a newline grows an unbounded
  buffer, unless `:max_line_bytes` bounds it.

  ## Deployment

  erlexec builds a C++ helper at `priv/<target>/exec-port`; releases must ship
  it, and it is architecture-specific. The helper also requires `SHELL` to be
  set in the environment.
  """

  alias RintoPMO.OSProcess.Instance
  alias RintoPMO.OSProcess.Spec

  @registry __MODULE__.Registry
  @dynamic_supervisor __MODULE__.DynamicSupervisor

  @typedoc "Caller-supplied instance identifier. Never interpreted."
  @type id :: String.t()

  @typedoc "An instance, addressed either by id or by the pid `start/1` returned."
  @type ref :: id() | pid()

  @typedoc "Whether output is delivered as raw chunks or complete lines."
  @type framing :: :raw | :lines

  @typedoc "Where the child's stderr goes."
  @type stderr_mode :: :owner | :stdout | :discard

  @typedoc """
  How the instance ended.

  `:exit` and `:signal` are the child's own status. `:stopped` means the
  instance was torn down first and carries the `terminate/2` reason.
  """
  @type exit_status ::
          {:exit, non_neg_integer()}
          | {:signal, atom() | integer(), boolean()}
          | {:stopped, term()}
          | {:error, term()}

  @type event :: {:stdout, binary()} | {:stderr, binary()} | {:exit, exit_status()}

  @type message :: {:os_process, id(), event()}

  @type info :: %{
          id: id(),
          pid: pid(),
          os_pid: pos_integer(),
          owner: pid(),
          argv: [String.t()]
        }

  @typedoc "Everything a finished `run/1` produced."
  @type run_result :: %{status: exit_status(), stdout: binary(), stderr: binary()}

  @typedoc "What a `run/1` had collected when it gave up."
  @type partial_result :: %{stdout: binary(), stderr: binary()}

  @type env_entry :: {String.t(), String.t() | false} | :clear

  @type start_opt ::
          {:id, id()}
          | {:cmd, String.t()}
          | {:args, [String.t()]}
          | {:cd, Path.t()}
          | {:env, [env_entry()]}
          | {:owner, pid() | atom()}
          | {:framing, framing()}
          | {:stderr, stderr_mode()}
          | {:max_line_bytes, pos_integer() | :infinity}
          | {:kill_timeout, pos_integer()}
          | {:drain_timeout, non_neg_integer()}
          | {:kill_group, boolean()}

  @type run_opt :: start_opt() | {:input, iodata()} | {:timeout, timeout()}

  @type start_error ::
          {:already_started, pid()}
          | {:executable_not_found, String.t()}
          | {:invalid_option, atom(), term()}
          | {:missing_option, atom()}
          | {:spawn_failed, term()}

  defmodule Behaviour do
    @moduledoc """
    The subset callers reach for when driving a child process.

    Exists so a caller can be tested without spawning anything. Deliberately
    partial: only what a mocked caller needs, since everything else is exercised
    against the real implementation.

    Mocking this covers the calls but not the messages -- output still arrives as
    `t:RintoPMO.OSProcess.message/0` sent to the owner, which a test fakes by
    sending to itself. That makes the message shape a contract a mock cannot
    check, so anything relying on it wants at least one test against the real
    module.
    """

    alias RintoPMO.OSProcess

    @callback start([OSProcess.start_opt()]) :: {:ok, pid()} | {:error, OSProcess.start_error()}
    @callback send(OSProcess.ref(), iodata()) :: :ok | {:error, OSProcess.call_error()}
    @callback stop(OSProcess.ref()) ::
                :ok | {:error, :not_found | :timeout | {:stop_failed, term()}}
  end

  @behaviour Behaviour

  @typedoc """
  Why a request to an instance failed.

  `:not_found` means no such instance, or one that died mid-request. `:timeout`
  means it is alive but did not answer -- distinct because the two call for
  different handling, and because writes ultimately go through erlexec's
  singleton server, which can be the thing that is slow.
  """
  @type call_error ::
          :not_found | :timeout | {:exec_busy, term()} | {:call_failed, term()}

  @default_call_timeout 5_000
  @default_run_timeout 30_000

  # Long enough to pick up the final exit event a stop/2 triggers, short enough
  # not to stall a caller whose run already failed.
  @leftover_timeout 500

  @doc """
  Starts an OS process.

  Only `:cmd` is required. Others:

    * `:id` - instance identifier, generated when omitted
    * `:args` - argument list, default `[]`
    * `:cd` - working directory, must exist
    * `:env` - `[{"NAME", "VALUE"}]` merged into the inherited environment;
      `{"NAME", false}` unsets an inherited variable and a bare `:clear` entry
      starts from an empty environment
    * `:owner` - process receiving output, by pid or registered name,
      default `self()`
    * `:framing` - `:raw` (default) or `:lines`
    * `:stderr` - `:owner` (default), `:stdout` to merge, or `:discard`
    * `:max_line_bytes` - under `framing: :lines`, cap the pending partial line
      at this many bytes, emitting a fragment rather than buffering without
      bound, default `:infinity`
    * `:kill_timeout` - **seconds** between SIGTERM and SIGKILL, default 5
    * `:drain_timeout` - milliseconds to keep collecting output after the child
      exits, default 25
    * `:kill_group` - also signal the child's process group, default `true`

  `:kill_timeout`, `:drain_timeout` and `:max_line_bytes` take their defaults
  from `config :rinto_pmo, RintoPMO.OSProcess` when it sets them.

  The owner is monitored: when it dies the instance stops and the OS process is
  killed. The instance is not linked to the owner, so an instance crash does not
  propagate outward.
  """
  @spec start([start_opt()]) :: {:ok, pid()} | {:error, start_error()}
  def start(opts) when is_list(opts) do
    with {:ok, spec} <- Spec.new(opts) do
      case DynamicSupervisor.start_child(@dynamic_supervisor, {Instance, spec}) do
        {:ok, pid} -> {:ok, pid}
        {:error, {:already_started, pid}} -> {:error, {:already_started, pid}}
        {:error, {reason, _stacktrace}} -> {:error, reason}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @doc """
  Runs a command to completion and returns everything it produced.

  Takes the same options as `start/1`, plus:

    * `:input` - written to stdin before it is closed, default `""`
    * `:timeout` - milliseconds to wait, default 30_000, or `:infinity`

  Blocks the calling process, which becomes the owner: `:owner` and `:framing`
  are ignored, since the whole point is to hand back complete buffers rather
  than a stream. stdin is always closed once `:input` is written, so a child
  that reads until EOF terminates on its own.

  On timeout the instance is stopped and whatever had arrived so far comes back
  with the error, which is usually what makes the failure diagnosable.

      iex> {:ok, result} = RintoPMO.OSProcess.run(cmd: "echo", args: ["hi"])
      iex> {result.status, result.stdout}
      {{:exit, 0}, "hi\\n"}
  """
  @spec run([run_opt()]) ::
          {:ok, run_result()} | {:error, start_error() | {:timeout, partial_result()}}
  def run(opts) when is_list(opts) do
    {timeout, opts} = Keyword.pop(opts, :timeout, @default_run_timeout)
    {input, opts} = Keyword.pop(opts, :input, "")

    # The id is settled before the child starts: looking it up afterwards would
    # race a command fast enough to exit first, and `echo` is that fast.
    id = Keyword.get_lazy(opts, :id, &generate_run_id/0)
    opts = Keyword.merge(opts, id: id, owner: self(), framing: :raw)

    with {:ok, _pid} <- start(opts) do
      _ = write_input(id, input)
      _ = close_stdin(id)
      collect(id, deadline(timeout), [], [])
    end
  end

  defp generate_run_id, do: "osproc-run-#{System.unique_integer([:positive, :monotonic])}"

  defp write_input(_id, ""), do: :ok
  defp write_input(id, input), do: __MODULE__.send(id, input)

  defp collect(id, deadline, stdout, stderr) do
    case remaining(deadline) do
      :expired ->
        give_up(id, stdout, stderr)

      wait ->
        receive do
          {:os_process, ^id, {:stdout, data}} -> collect(id, deadline, [data | stdout], stderr)
          {:os_process, ^id, {:stderr, data}} -> collect(id, deadline, stdout, [data | stderr])
          {:os_process, ^id, {:exit, status}} -> {:ok, result(stdout, stderr, status)}
        after
          wait -> give_up(id, stdout, stderr)
        end
    end
  end

  # Stopping makes the instance emit its final event; collecting the leftovers
  # keeps them out of the caller's mailbox, where nothing would ever read them.
  defp give_up(id, stdout, stderr) do
    _ = stop(id)
    {:error, {:timeout, drain_leftovers(id, stdout, stderr)}}
  end

  defp drain_leftovers(id, stdout, stderr) do
    receive do
      {:os_process, ^id, {:stdout, data}} -> drain_leftovers(id, [data | stdout], stderr)
      {:os_process, ^id, {:stderr, data}} -> drain_leftovers(id, stdout, [data | stderr])
      {:os_process, ^id, {:exit, _status}} -> result(stdout, stderr)
    after
      @leftover_timeout -> result(stdout, stderr)
    end
  end

  defp result(stdout, stderr), do: %{stdout: join(stdout), stderr: join(stderr)}

  defp result(stdout, stderr, status),
    do: %{status: status, stdout: join(stdout), stderr: join(stderr)}

  defp join(reversed_chunks), do: reversed_chunks |> Enum.reverse() |> IO.iodata_to_binary()

  defp deadline(:infinity), do: :infinity

  defp deadline(timeout) when is_integer(timeout) and timeout >= 0,
    do: System.monotonic_time(:millisecond) + timeout

  defp remaining(:infinity), do: :infinity

  defp remaining(deadline) do
    case deadline - System.monotonic_time(:millisecond) do
      left when left > 0 -> left
      _expired -> :expired
    end
  end

  @doc """
  Writes to the child's stdin.

  Writes are serialized through the instance, so ordering holds across
  concurrent callers.
  """
  @spec send(ref(), iodata(), timeout()) :: :ok | {:error, call_error()}
  def send(ref, data, timeout \\ @default_call_timeout) do
    call(ref, {:send, IO.iodata_to_binary(data)}, timeout)
  end

  @doc """
  Closes the child's stdin, signalling end of input.
  """
  @spec close_stdin(ref(), timeout()) :: :ok | {:error, call_error()}
  def close_stdin(ref, timeout \\ @default_call_timeout),
    do: call(ref, :close_stdin, timeout)

  @doc """
  Stops the instance and its OS process, waiting for the reap.

  erlexec sends SIGTERM, then SIGKILL after the instance's `:kill_timeout`. The
  owner receives a final `{:exit, {:stopped, :normal}}`.
  """
  @spec stop(ref(), timeout()) :: :ok | {:error, :not_found | :timeout | {:stop_failed, term()}}
  def stop(ref, timeout \\ 10_000) do
    case resolve(ref) do
      {:ok, pid} -> stop_pid(pid, timeout)
      :error -> {:error, :not_found}
    end
  end

  defp stop_pid(pid, timeout) do
    GenServer.stop(pid, :normal, timeout)
  catch
    # Raced with the process exiting on its own; the goal is already met.
    :exit, reason when reason in [:noproc, :normal, :shutdown] -> :ok
    # A stop that timed out left the OS process running. Reporting :ok here
    # would tell the caller the opposite of what happened.
    :exit, :timeout -> {:error, :timeout}
    :exit, reason -> {:error, {:stop_failed, reason}}
  end

  @doc """
  Sends a signal to the OS process, e.g. `:sigkill` or `9`.
  """
  @spec kill(ref(), atom() | pos_integer(), timeout()) :: :ok | {:error, call_error() | term()}
  def kill(ref, signal, timeout \\ @default_call_timeout),
    do: call(ref, {:kill, signal}, timeout)

  @doc """
  Returns the instance pid for `id`.
  """
  @spec whereis(id()) :: {:ok, pid()} | :error
  def whereis(id) when is_binary(id) do
    case Registry.lookup(@registry, id) do
      [{pid, _value}] -> {:ok, pid}
      [] -> :error
    end
  end

  @doc """
  Returns details about a running instance.
  """
  @spec info(ref()) :: {:ok, info()} | {:error, call_error()}
  def info(pid) when is_pid(pid), do: call(pid, :info, @default_call_timeout)

  def info(id) when is_binary(id) do
    case Registry.lookup(@registry, id) do
      [{pid, %{os_pid: os_pid, argv: argv, owner: owner}}] ->
        {:ok, %{id: id, pid: pid, os_pid: os_pid, owner: owner, argv: argv}}

      # Registered, but `init/1` has not published the value yet. Asking the
      # instance blocks until it has, which beats reporting a process that is
      # plainly in `list/0` as missing.
      [{pid, _pending}] ->
        call(pid, :info, @default_call_timeout)

      [] ->
        {:error, :not_found}
    end
  end

  @doc """
  Lists the ids of all running instances.
  """
  @spec list() :: [id()]
  def list do
    Registry.select(@registry, [{{:"$1", :_, :_}, [], [:"$1"]}])
  end

  @doc """
  Returns whether an instance is running.
  """
  @spec running?(ref()) :: boolean()
  def running?(pid) when is_pid(pid), do: Process.alive?(pid)
  def running?(id) when is_binary(id), do: match?({:ok, _pid}, whereis(id))

  defp resolve(pid) when is_pid(pid), do: {:ok, pid}
  defp resolve(id) when is_binary(id), do: whereis(id)

  defp call(ref, request, timeout) do
    case resolve(ref) do
      {:ok, pid} -> GenServer.call(pid, request, timeout)
      :error -> {:error, :not_found}
    end
  catch
    # The instance died between the lookup and the call, or during it. From the
    # caller's side that is indistinguishable from it never having been there.
    :exit, {reason, _call} when reason in [:noproc, :normal, :shutdown] ->
      {:error, :not_found}

    # Alive but unresponsive, which is a different problem entirely: the write
    # path runs through erlexec's singleton server and can be the bottleneck.
    :exit, {:timeout, _call} ->
      {:error, :timeout}

    :exit, reason ->
      {:error, {:call_failed, reason}}
  end
end
