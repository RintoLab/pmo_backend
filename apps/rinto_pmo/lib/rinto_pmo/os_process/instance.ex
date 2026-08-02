defmodule RintoPMO.OSProcess.Instance do
  @moduledoc false

  # One GenServer per running OS process. Owns the erlexec handle, forwards
  # output to the owner, and guarantees the OS process dies with it.

  use GenServer

  require Logger

  alias RintoPMO.OSProcess.LineBuffer
  alias RintoPMO.OSProcess.Spec

  @registry RintoPMO.OSProcess.Registry

  @doc false
  def child_spec(%Spec{} = spec) do
    %{
      id: {__MODULE__, spec.id},
      start: {__MODULE__, :start_link, [spec]},
      restart: :temporary,
      shutdown: Spec.shutdown_timeout(spec),
      type: :worker
    }
  end

  @doc false
  @spec start_link(Spec.t()) :: GenServer.on_start()
  def start_link(%Spec{} = spec) do
    GenServer.start_link(__MODULE__, spec, name: via(spec.id))
  end

  defp via(id), do: {:via, Registry, {@registry, id, %{}}}

  @impl true
  def init(%Spec{} = spec) do
    Process.flag(:trap_exit, true)
    owner_ref = Process.monitor(spec.owner)

    case :exec.run(spec.argv, spec.exec_opts) do
      {:ok, exec_pid, os_pid} ->
        Registry.update_value(@registry, spec.id, fn _ ->
          %{os_pid: os_pid, argv: spec.argv, owner: spec.owner}
        end)

        {:ok,
         %{
           spec: spec,
           exec_pid: exec_pid,
           os_pid: os_pid,
           owner_ref: owner_ref,
           stdout: LineBuffer.new(spec.max_line_bytes),
           stderr: LineBuffer.new(spec.max_line_bytes),
           pending_exit: nil
         }}

      {:error, reason} ->
        {:stop, {:spawn_failed, reason}}
    end
  end

  @impl true
  def handle_call(:info, _from, state) do
    info = %{
      id: state.spec.id,
      pid: self(),
      os_pid: state.os_pid,
      owner: state.spec.owner,
      argv: state.spec.argv
    }

    {:reply, {:ok, info}, state}
  end

  # Serializing writes through this process guarantees ordering between
  # concurrent callers. The catch is required because :exec.send/2 is a
  # gen_server:call into the singleton exec server, which can exit under
  # load -- letting that propagate would kill a healthy OS process.
  def handle_call({:send, data}, _from, state) do
    {:reply, exec_send(state.exec_pid, data), state}
  end

  def handle_call(:close_stdin, _from, state) do
    {:reply, exec_send(state.exec_pid, :eof), state}
  end

  def handle_call({:kill, signal}, _from, state) do
    {:reply, normalize_ok(:exec.kill(state.exec_pid, signal)), state}
  end

  defp exec_send(exec_pid, data) do
    normalize_ok(:exec.send(exec_pid, data))
  catch
    :exit, reason -> {:error, {:exec_busy, reason}}
  end

  defp normalize_ok(:ok), do: :ok
  defp normalize_ok({:error, _reason} = error), do: error

  @impl true
  def handle_info({stream, os_pid, data}, %{os_pid: os_pid} = state)
      when stream in [:stdout, :stderr] do
    {:noreply, emit_output(state, stream, data)}
  end

  # The OS process exited. Output is forwarded by the singleton exec server
  # while this EXIT comes from erlexec's per-process pid -- different senders,
  # so trailing output can still arrive. Drain briefly before reporting.
  def handle_info({:EXIT, exec_pid, reason}, %{exec_pid: exec_pid} = state) do
    Process.send_after(self(), :drain_done, state.spec.drain_timeout)
    {:noreply, %{state | pending_exit: exit_status(reason)}}
  end

  def handle_info(:drain_done, state) do
    _ = report_exit(state, state.pending_exit)
    {:stop, :normal, %{state | exec_pid: nil}}
  end

  def handle_info({:DOWN, owner_ref, :process, _pid, _reason}, %{owner_ref: owner_ref} = state) do
    {:stop, :normal, state}
  end

  def handle_info(message, state) do
    Logger.debug("#{inspect(__MODULE__)} #{state.spec.id} ignoring #{inspect(message)}")
    {:noreply, state}
  end

  # Every path out of this process must deliver exactly one {:exit, _} to the
  # owner, so each clause below either reports one or documents why the event
  # has already gone out.

  # The drain already reported the child's own exit status.
  @impl true
  def terminate(_reason, %{exec_pid: nil}), do: :ok

  # Torn down mid-drain. The child is already gone -- stopping it again would
  # make erlexec log a spurious "pid not alive" warning -- but the exit event
  # it earned has not been sent yet, so send it rather than inventing a reason.
  def terminate(_reason, %{pending_exit: pending} = state) when pending != nil do
    report_exit(state, pending)
  end

  # The child may have exited already with its {:EXIT, ...} still unprocessed in
  # the mailbox -- a stop/2 that raced the child finishing on its own. Reporting
  # the status it actually earned beats inventing a `:stopped` one, and skipping
  # the redundant :exec.stop/1 avoids erlexec's "pid not alive" warning.
  def terminate(reason, %{exec_pid: exec_pid} = state) do
    receive do
      {:EXIT, ^exec_pid, exit_reason} -> report_exit(state, exit_status(exit_reason))
    after
      0 -> stop_and_report(state, reason)
    end
  end

  # Deliberately not :exec.stop_and_wait/2 -- it waits for a {:DOWN, ...} that
  # only ever arrives for instances started with `:monitor`. We use `:link`, so
  # it would block for the full timeout every single time. Monitoring here also
  # returns immediately when the pid is already dead.
  #
  # The reap wait is capped below the supervisor's shutdown timeout so that the
  # {:exit, {:stopped, _}} still gets out even in the worst case.
  defp stop_and_report(%{exec_pid: exec_pid, spec: spec} = state, reason) do
    ref = Process.monitor(exec_pid)
    _ = stop_exec(exec_pid)

    receive do
      {:DOWN, ^ref, :process, ^exec_pid, _reason} -> :ok
    after
      Spec.reap_timeout(spec) -> :ok
    end

    notify(state, {:exit, {:stopped, reason}})
    :ok
  end

  defp report_exit(state, status) do
    _ =
      state
      |> flush_stream(:stdout)
      |> flush_stream(:stderr)
      |> notify({:exit, status})

    :ok
  end

  # Skipping a stop for an already-dead handle avoids an "unknown msg: pid not
  # alive" warning from erlexec. This narrows the race rather than closing it:
  # the child can still die between the check and the call, which is harmless.
  defp stop_exec(exec_pid) do
    if Process.alive?(exec_pid), do: :exec.stop(exec_pid), else: :ok
  catch
    # Already gone, or the exec server is unavailable. erlexec's link has done
    # (or will do) the reaping either way.
    :exit, _reason -> :ok
  end

  defp emit_output(%{spec: %Spec{framing: :raw}} = state, stream, data) do
    notify(state, {stream, data})
    state
  end

  defp emit_output(%{spec: %Spec{framing: :lines}} = state, stream, data) do
    {lines, buffer} = LineBuffer.push(Map.fetch!(state, stream), data)
    Enum.each(lines, &notify(state, {stream, &1}))
    Map.put(state, stream, buffer)
  end

  defp flush_stream(%{spec: %Spec{framing: :raw}} = state, _stream), do: state

  defp flush_stream(%{spec: %Spec{framing: :lines}} = state, stream) do
    {lines, buffer} = LineBuffer.flush(Map.fetch!(state, stream))
    Enum.each(lines, &notify(state, {stream, &1}))
    Map.put(state, stream, buffer)
  end

  defp notify(%{spec: spec} = state, event) do
    send(spec.owner, {:os_process, spec.id, event})
    state
  end

  # erlexec reports a raw wait(2) status; :exec.status/1 is the only correct
  # way to tell an exit code from a terminating signal.
  defp exit_status(:normal), do: {:exit, 0}

  defp exit_status({:exit_status, raw}) do
    case :exec.status(raw) do
      {:status, code} -> {:exit, code}
      {:signal, signal, core?} -> {:signal, signal, core?}
    end
  end

  defp exit_status(reason), do: {:error, reason}
end
