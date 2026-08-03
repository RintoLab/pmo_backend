defmodule RintoPMO.OSProcess.Instance do
  @moduledoc false

  # One GenServer per running OS process. Owns the erlexec handle, forwards
  # output to the owner, and guarantees the OS process dies with it.

  use GenServer

  require Logger

  alias RintoPMO.OSProcess.LineBuffer
  alias RintoPMO.OSProcess.Spec

  @registry RintoPMO.OSProcess.Registry

  # How long a stopped child is given to go away before it is signalled again,
  # and how many times. Long enough that the child is past execve in practice,
  # short enough that stopping a healthy process is not noticeably delayed.
  @resignal_after 50
  @resignals 2

  # How long terminate/2 waits for an exit the child has already earned before
  # deciding it has to signal instead.
  #
  # Stopping a child that has exited but has not been reaped yet leaves erlexec
  # inconsistent: the signal goes to a process group holding nothing but a
  # zombie and fails, and erlexec answers a signal it could not deliver by
  # dropping the child from its table without ever reporting the status it had
  # (deps/erlexec/c_src/exec_impl.cpp, stop_child/4). The owner then gets an
  # invented `:stopped` instead of the real status, and erlexec logs
  # `unknown msg: {error, "pid not alive"}` once the instance dies and the
  # stale entry it left behind is cleaned up.
  #
  # Whenever that happens the child's exit is already travelling port -> exec
  # server -> instance, a few hundred microseconds away, so a short wait turns
  # the race into a clean report. A stop that really does have to kill something
  # pays the wait in full, which is immaterial next to the signal round trip
  # that follows it.
  @exit_grace 10

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

  # A stop that races the child finishing on its own, which is the normal ending
  # for a short-lived child whose owner tears it down as it completes. Reporting
  # the status the child actually earned beats inventing a `:stopped` one, and
  # not signalling a child that is already gone is what keeps erlexec consistent
  # -- see @exit_grace.
  def terminate(reason, %{exec_pid: exec_pid} = state) do
    receive do
      {:EXIT, ^exec_pid, exit_reason} -> report_exit(state, exit_status(exit_reason))
    after
      @exit_grace -> stop_and_report(state, reason)
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

    case stop_exec(exec_pid) do
      :ok ->
        await_reap(exec_pid, ref, deadline(Spec.reap_timeout(spec)), @resignals)

      # erlexec could not signal the OS process, which means the child died
      # inside the grace window @exit_grace was meant to cover, leaving its
      # process group empty. erlexec answers that by dropping the child from its
      # table, so the notification this wait is for is never coming -- and
      # waiting for it would burn the whole reap timeout.
      {:error, _reason} ->
        Process.demonitor(ref, [:flush])
    end

    notify(state, {:exit, {:stopped, reason}})
    :ok
  end

  # erlexec loses the first SIGTERM when a stop races a start: until the child's
  # execve completes it still carries exec-port's signal dispositions, and it is
  # not yet in the process group the signal is aimed at. erlexec never re-sends
  # -- `stop_child` records the attempt and only escalates to SIGKILL once
  # :kill_timeout expires (deps/erlexec/c_src/exec_impl.cpp) -- so the stop
  # blocks for that whole grace, five seconds by default. Re-signalling a child
  # that has not gone away lands on the exec'd process and reaps it at once.
  #
  # A child ignoring SIGTERM on purpose loses nothing: the extra signals are as
  # ignored as the first, and erlexec's SIGKILL is still the backstop.
  defp await_reap(exec_pid, ref, deadline, resignals_left) do
    wait =
      if resignals_left > 0,
        do: min(@resignal_after, remaining(deadline)),
        else: remaining(deadline)

    receive do
      {:DOWN, ^ref, :process, ^exec_pid, _reason} ->
        :ok
    after
      wait ->
        if resignals_left > 0 do
          _ = resignal(exec_pid)
          await_reap(exec_pid, ref, deadline, resignals_left - 1)
        else
          :ok
        end
    end
  end

  # :exec.kill/2 rather than another :exec.stop/1, which is a no-op once erlexec
  # has recorded a SIGTERM attempt. It signals the child alone rather than its
  # group -- erlexec rejects a negative pid -- which is the right target here:
  # the group is what the lost signal could not reach, and erlexec SIGTERMs the
  # rest of it once the child exits.
  #
  # Skipping a dead handle avoids erlexec's "pid not alive" warning, exactly as
  # in stop_exec/1 above.
  defp resignal(exec_pid) do
    if Process.alive?(exec_pid), do: :exec.kill(exec_pid, :sigterm), else: :ok
  catch
    :exit, _reason -> :ok
  end

  defp deadline(timeout), do: System.monotonic_time(:millisecond) + timeout

  defp remaining(deadline), do: max(0, deadline - System.monotonic_time(:millisecond))

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
  #
  # Failures return `{:error, _}` so `stop_and_report/2` does not wait on a
  # DOWN that is not coming; the instance's link still reaps the LWP on exit.
  defp stop_exec(exec_pid) do
    if Process.alive?(exec_pid), do: :exec.stop(exec_pid), else: :ok
  catch
    :exit, reason -> {:error, {:exec_unavail, reason}}
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
