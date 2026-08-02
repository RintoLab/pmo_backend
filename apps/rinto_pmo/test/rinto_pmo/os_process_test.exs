defmodule RintoPMO.OSProcessTest do
  use ExUnit.Case, async: true

  alias RintoPMO.OSProcess

  @moduletag :capture_log

  # Every test uses a fresh id, so the shared registry and the singleton
  # erlexec server do not couple tests together.
  defp unique_id, do: "os-process-test-#{System.unique_integer([:positive])}"

  defp start!(opts) do
    id = Keyword.get_lazy(opts, :id, &unique_id/0)
    opts = Keyword.put(opts, :id, id)

    assert {:ok, _pid} = OSProcess.start(opts)
    on_exit(fn -> OSProcess.stop(id) end)

    id
  end

  defp sh(script), do: [cmd: "/bin/sh", args: ["-c", script]]

  # A child that announces itself before blocking forever. Waiting for that
  # announcement is not just tidiness: erlexec's SIGTERM is lost if it lands in
  # the window between fork and execve, and the stop then costs a full
  # `:kill_timeout` instead of milliseconds. Tests that mean to kill a *running*
  # child say so, and stay fast as a side effect.
  defp long_running, do: sh("printf 'up\n'; sleep 60")

  defp await_started(id) do
    assert_receive {:os_process, ^id, {:stdout, "up\n"}}, 2_000
    id
  end

  # erlexec reports every OS process it still manages, so "is it really gone?"
  # needs no sleeping or polling.
  defp managed?(os_pid), do: os_pid in :exec.which_children()

  # Grandchildren are not managed by erlexec, so liveness has to come from the
  # OS. `kill -0` signals nothing and only reports whether the pid is reachable.
  defp alive_os_pid?(os_pid) do
    {_output, status} =
      System.cmd("/bin/sh", ["-c", "kill -0 #{String.trim(os_pid)} 2>/dev/null"])

    status == 0
  end

  describe "stdout" do
    test "streams output and reports a clean exit" do
      id = start!(sh("printf 'hello\n'"))

      assert_receive {:os_process, ^id, {:stdout, "hello\n"}}
      assert_receive {:os_process, ^id, {:exit, {:exit, 0}}}
    end

    test "reports a non-zero exit code" do
      id = start!(sh("exit 3"))

      assert_receive {:os_process, ^id, {:exit, {:exit, 3}}}
    end

    test "reports termination by signal" do
      id = start!(sh("sleep 60"))

      assert :ok = OSProcess.kill(id, :sigkill)
      assert_receive {:os_process, ^id, {:exit, {:signal, _signal, _core?}}}, 2_000
    end
  end

  describe "stdin" do
    test "echoes data written to the child" do
      id = start!(cmd: "cat", args: ["-u"], framing: :lines)

      assert :ok = OSProcess.send(id, "ping\n")
      assert_receive {:os_process, ^id, {:stdout, "ping"}}
    end

    test "closing stdin ends a filter process" do
      id = start!(cmd: "cat", args: ["-u"], framing: :lines)

      assert :ok = OSProcess.send(id, "bye\n")
      assert_receive {:os_process, ^id, {:stdout, "bye"}}

      assert :ok = OSProcess.close_stdin(id)
      assert_receive {:os_process, ^id, {:exit, {:exit, 0}}}, 2_000
    end

    test "returns an error for an unknown id" do
      assert {:error, :not_found} = OSProcess.send("nope", "data")
      assert {:error, :not_found} = OSProcess.close_stdin("nope")
    end
  end

  describe "framing" do
    test "lines mode splits on newlines and flushes the trailing partial" do
      id = start!(sh("printf 'a\nb\nc'") ++ [framing: :lines])

      assert_receive {:os_process, ^id, {:stdout, "a"}}
      assert_receive {:os_process, ^id, {:stdout, "b"}}
      # "c" has no trailing newline: it must still arrive, and before the exit.
      assert_receive {:os_process, ^id, {:stdout, "c"}}
      assert_receive {:os_process, ^id, {:exit, {:exit, 0}}}
    end

    test "lines mode preserves blank lines" do
      id = start!(sh("printf 'a\n\nb\n'") ++ [framing: :lines])

      assert_receive {:os_process, ^id, {:stdout, "a"}}
      assert_receive {:os_process, ^id, {:stdout, ""}}
      assert_receive {:os_process, ^id, {:stdout, "b"}}
    end

    test "raw mode delivers chunks without waiting for a newline" do
      id = start!(sh("printf 'ab'"))

      assert_receive {:os_process, ^id, {:stdout, "ab"}}
      assert_receive {:os_process, ^id, {:exit, {:exit, 0}}}
    end
  end

  describe "stderr routing" do
    test "delivers stderr as its own stream by default" do
      id = start!(sh("printf 'oops\n' 1>&2"))

      assert_receive {:os_process, ^id, {:stderr, "oops\n"}}
    end

    test "merges stderr into stdout when asked" do
      id = start!(sh("printf 'oops\n' 1>&2") ++ [stderr: :stdout])

      assert_receive {:os_process, ^id, {:stdout, "oops\n"}}
      refute_received {:os_process, ^id, {:stderr, _}}
    end

    test "discards stderr when asked" do
      id = start!(sh("printf 'oops\n' 1>&2; printf 'kept\n'") ++ [stderr: :discard])

      assert_receive {:os_process, ^id, {:stdout, "kept\n"}}
      refute_received {:os_process, ^id, {:stderr, _}}
    end
  end

  describe "environment" do
    test "passes env vars to the child" do
      id = start!(sh(~s(printf '%s' "$FOO")) ++ [env: [{"FOO", "bar"}]])

      assert_receive {:os_process, ^id, {:stdout, "bar"}}
    end

    test "runs in the requested working directory" do
      # Not tmp_dir: on macOS /tmp is a symlink and pwd reports the real path.
      cwd = File.cwd!()
      id = start!(sh("pwd") ++ [cd: cwd])

      assert_receive {:os_process, ^id, {:stdout, output}}
      assert String.trim(output) == cwd
    end
  end

  describe "multiple instances" do
    test "keeps concurrent instances isolated" do
      first = start!(cmd: "cat", args: ["-u"], framing: :lines)
      second = start!(cmd: "cat", args: ["-u"], framing: :lines)

      assert :ok = OSProcess.send(first, "one\n")
      assert :ok = OSProcess.send(second, "two\n")

      assert_receive {:os_process, ^first, {:stdout, "one"}}
      assert_receive {:os_process, ^second, {:stdout, "two"}}

      refute_received {:os_process, ^first, {:stdout, "two"}}
      refute_received {:os_process, ^second, {:stdout, "one"}}

      ids = OSProcess.list()
      assert first in ids
      assert second in ids

      assert {:ok, %{os_pid: first_os_pid}} = OSProcess.info(first)
      assert {:ok, %{os_pid: second_os_pid}} = OSProcess.info(second)
      assert first_os_pid != second_os_pid
    end

    test "rejects a duplicate id" do
      id = start!(cmd: "cat", args: ["-u"])

      assert {:error, {:already_started, _pid}} = OSProcess.start(id: id, cmd: "cat")
      assert OSProcess.running?(id)
    end
  end

  describe "start/1 errors" do
    test "reports a missing executable without registering the id" do
      id = unique_id()
      cmd = "no-such-binary-#{System.unique_integer([:positive])}"

      assert {:error, {:executable_not_found, ^cmd}} = OSProcess.start(id: id, cmd: cmd)
      refute id in OSProcess.list()
      refute OSProcess.running?(id)
    end

    test "reports invalid options" do
      assert {:error, {:missing_option, :cmd}} = OSProcess.start(id: unique_id())

      assert {:error, {:invalid_option, :framing, :nope}} =
               OSProcess.start(id: unique_id(), cmd: "cat", framing: :nope)
    end
  end

  describe "stop/2" do
    test "kills a long-running child and deregisters it" do
      id = long_running() |> start!() |> await_started()
      assert {:ok, %{pid: pid, os_pid: os_pid}} = OSProcess.info(id)
      ref = Process.monitor(pid)

      assert :ok = OSProcess.stop(id)

      assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 5_000
      refute managed?(os_pid)
      assert {:error, :not_found} = OSProcess.info(id)
      refute OSProcess.running?(id)
    end

    # The owner has no other way to learn the instance is gone, so an explicit
    # stop has to close the event stream just like a natural exit does.
    test "reports the teardown to the owner as a final exit event" do
      id = long_running() |> start!() |> await_started()

      assert :ok = OSProcess.stop(id)

      assert_receive {:os_process, ^id, {:exit, {:stopped, :normal}}}, 5_000
    end

    test "delivers exactly one exit event when the child exits on its own" do
      id = start!(sh("exit 0"))

      assert_receive {:os_process, ^id, {:exit, {:exit, 0}}}
      assert eventually(fn -> not OSProcess.running?(id) end)

      refute_received {:os_process, ^id, {:exit, _other}}
    end

    test "returns an error for an unknown id" do
      assert {:error, :not_found} = OSProcess.stop("nope")
    end

    # The signal erlexec sends is lost if it lands between fork and execve, and
    # erlexec never re-sends one -- it only escalates to SIGKILL at
    # `:kill_timeout`. Stopping without waiting for the child to announce itself
    # is the way to land in that window, so this deliberately skips the
    # `await_started/1` every other stop test uses.
    #
    # The race does not fire every run, so a single fast stop proves nothing --
    # repeat until one of them has hit the window. Asserting on the total keeps
    # a re-signal that stopped working from passing as merely slow.
    test "stays fast when the stop races the start" do
      {elapsed, _} =
        :timer.tc(fn ->
          for _ <- 1..8 do
            id = start!(long_running())
            assert :ok = OSProcess.stop(id)
          end
        end)

      # Eight stops that each waited out `:kill_timeout` (1s under test config)
      # would take ~8s; eight re-signalled ones take well under one.
      assert div(elapsed, 1_000) < 2_000
    end
  end

  describe "addressing" do
    test "accepts a pid anywhere an id works" do
      id = unique_id()
      assert {:ok, pid} = OSProcess.start([id: id] ++ [cmd: "cat", args: ["-u"], framing: :lines])
      on_exit(fn -> OSProcess.stop(id) end)

      assert :ok = OSProcess.send(pid, "via-pid\n")
      assert_receive {:os_process, ^id, {:stdout, "via-pid"}}

      assert {:ok, %{id: ^id, pid: ^pid}} = OSProcess.info(pid)
      assert OSProcess.running?(pid)

      assert :ok = OSProcess.stop(pid)
      refute OSProcess.running?(pid)
    end

    test "generates an id when none is given" do
      assert {:ok, pid} = OSProcess.start(cmd: "cat", args: ["-u"])
      on_exit(fn -> OSProcess.stop(pid) end)

      assert {:ok, %{id: id}} = OSProcess.info(pid)
      assert is_binary(id)
      assert id in OSProcess.list()
    end

    test "sends output to an owner given by registered name" do
      name = :"os_process_owner_#{System.unique_integer([:positive])}"
      Process.register(self(), name)

      id = start!(sh("printf 'named\n'") ++ [owner: name])

      assert_receive {:os_process, ^id, {:stdout, "named\n"}}
    end
  end

  describe "call errors" do
    # Reporting a busy instance as :not_found would send the caller looking for
    # a process that is in fact alive and merely slow.
    test "distinguishes an unresponsive instance from a missing one" do
      id = start!(cmd: "cat", args: ["-u"])
      {:ok, %{pid: pid}} = OSProcess.info(id)

      :sys.suspend(pid)
      result = OSProcess.send(id, "blocked\n", 50)
      :sys.resume(pid)

      assert {:error, :timeout} = result
      assert OSProcess.running?(id)
      assert {:error, :not_found} = OSProcess.send(unique_id(), "gone\n")
    end
  end

  describe "kill_group" do
    # erlexec only calls setpgid() when a `group` option is present, so without
    # `{group, 0}` a group kill would signal exec-port's own group and take down
    # every other instance with it. That is what the surviving `bystander` here
    # is guarding against.
    test "kills grandchildren without disturbing other instances" do
      bystander = start!(cmd: "cat", args: ["-u"], framing: :lines)
      id = start!(sh("sleep 300 & echo $!; wait") ++ [framing: :lines])

      assert_receive {:os_process, ^id, {:stdout, grandchild}}, 5_000
      assert alive_os_pid?(grandchild)

      assert :ok = OSProcess.stop(id)

      assert eventually(fn -> not alive_os_pid?(grandchild) end)

      assert OSProcess.running?(bystander)
      assert :ok = OSProcess.send(bystander, "still here\n")
      assert_receive {:os_process, ^bystander, {:stdout, "still here"}}, 5_000
    end

    test "leaves grandchildren alone when disabled" do
      id = start!(sh("sleep 2 & echo $!; wait") ++ [framing: :lines, kill_group: false])

      assert_receive {:os_process, ^id, {:stdout, grandchild}}, 5_000

      assert :ok = OSProcess.stop(id)
      # The grandchild is orphaned rather than reaped; it exits on its own.
      assert alive_os_pid?(grandchild)
    end
  end

  describe "max_line_bytes" do
    test "cuts an over-long line into fragments instead of buffering it" do
      id = start!(sh("printf 'aaaaaaaa\n'") ++ [framing: :lines, max_line_bytes: 4])

      assert_receive {:os_process, ^id, {:stdout, "aaaa"}}
      assert_receive {:os_process, ^id, {:stdout, "aaaa"}}
      assert_receive {:os_process, ^id, {:exit, {:exit, 0}}}
    end

    test "leaves lines under the limit untouched" do
      id = start!(sh("printf 'ab\ncd\n'") ++ [framing: :lines, max_line_bytes: 16])

      assert_receive {:os_process, ^id, {:stdout, "ab"}}
      assert_receive {:os_process, ^id, {:stdout, "cd"}}
    end
  end

  describe "run/1" do
    test "collects stdout and the exit status" do
      assert {:ok, result} = OSProcess.run(cmd: "echo", args: ["hi"])
      assert result.status == {:exit, 0}
      assert result.stdout == "hi\n"
      assert result.stderr == ""
    end

    test "reports a non-zero exit alongside the output" do
      assert {:ok, result} = OSProcess.run(sh("printf 'out'; printf 'err' 1>&2; exit 7"))

      assert result.status == {:exit, 7}
      assert result.stdout == "out"
      assert result.stderr == "err"
    end

    test "writes input and closes stdin" do
      assert {:ok, result} = OSProcess.run([cmd: "cat", input: "piped\n"] ++ [])

      assert result.status == {:exit, 0}
      assert result.stdout == "piped\n"
    end

    test "closes stdin even without input, so a filter terminates" do
      assert {:ok, %{status: {:exit, 0}, stdout: ""}} = OSProcess.run(cmd: "cat")
    end

    test "returns what it had collected when it times out" do
      assert {:error, {:timeout, partial}} =
               OSProcess.run(sh("printf 'partial'; sleep 30") ++ [timeout: 300])

      assert partial.stdout == "partial"
    end

    test "leaves no instance behind after a timeout" do
      id = unique_id()

      assert {:error, {:timeout, _partial}} =
               OSProcess.run(sh("sleep 30") ++ [id: id, timeout: 200])

      assert eventually(fn -> not OSProcess.running?(id) end)
    end

    test "leaves no stray messages in the caller's mailbox" do
      id = unique_id()

      assert {:error, {:timeout, _partial}} =
               OSProcess.run(sh("printf 'x'; sleep 30") ++ [id: id, timeout: 200])

      refute_received {:os_process, ^id, _event}
    end

    test "surfaces start errors without waiting" do
      assert {:error, {:executable_not_found, "definitely-not-a-binary"}} =
               OSProcess.run(cmd: "definitely-not-a-binary")
    end

    test "honours cd and env" do
      cwd = File.cwd!()

      assert {:ok, result} =
               OSProcess.run(sh(~s(pwd; printf '%s' "$FOO")) ++ [cd: cwd, env: [{"FOO", "bar"}]])

      assert result.stdout == cwd <> "\n" <> "bar"
    end

    # Two traps here. System.put_env/2 would not work as a probe: erlexec's
    # exec-port helper is spawned once at application start and children inherit
    # *its* environment, so anything the BEAM sets afterwards never reaches
    # them. PATH is no good either -- sh substitutes a built-in default when it
    # is missing, so unsetting it looks like a no-op. ROOTDIR is set by the
    # Erlang launcher itself and left alone by the shell.
    test "unsets an inherited variable" do
      assert {:ok, kept} = OSProcess.run(sh(~s(printf '%s' "$ROOTDIR")))
      refute kept.stdout == ""

      assert {:ok, dropped} =
               OSProcess.run(sh(~s(printf '%s' "$ROOTDIR")) ++ [env: [{"ROOTDIR", false}]])

      assert dropped.stdout == ""
    end

    test "clears the whole inherited environment" do
      assert {:ok, result} =
               OSProcess.run(
                 sh(~s(printf '%s|%s' "$ROOTDIR" "$ONLY")) ++ [env: [:clear, {"ONLY", "one"}]]
               )

      assert result.stdout == "|one"
    end
  end

  describe "lifecycle" do
    test "instance stops itself when the child exits, freeing the id" do
      id = start!(sh("exit 0"))

      assert_receive {:os_process, ^id, {:exit, {:exit, 0}}}
      # The id must become reusable, so wait for the instance to actually go.
      assert eventually(fn -> not OSProcess.running?(id) end)

      assert {:ok, _pid} = OSProcess.start(id: id, cmd: "cat", args: ["-u"])
      on_exit(fn -> OSProcess.stop(id) end)
    end

    test "killing the owner reaps the OS process" do
      test_pid = self()

      # Forwarding lets the test see the child come up without becoming its
      # owner, which is the whole point of the scenario.
      owner = spawn(fn -> forward_forever(test_pid) end)

      id = unique_id()
      assert {:ok, pid} = OSProcess.start([owner: owner, id: id] ++ long_running())
      on_exit(fn -> OSProcess.stop(id) end)

      assert_receive {:forwarded, {:os_process, ^id, {:stdout, "up\n"}}}, 2_000
      assert {:ok, %{os_pid: os_pid}} = OSProcess.info(id)
      ref = Process.monitor(pid)

      # The owner never linked to us, so this must not disturb the test process.
      Process.exit(owner, :kill)

      assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 5_000
      refute managed?(os_pid)
      assert Process.alive?(test_pid)
    end
  end

  defp forward_forever(target) do
    receive do
      message -> send(target, {:forwarded, message})
    end

    forward_forever(target)
  end

  defp eventually(fun, attempts \\ 50)
  defp eventually(_fun, 0), do: false

  defp eventually(fun, attempts) do
    if fun.() do
      true
    else
      receive do
      after
        20 -> eventually(fun, attempts - 1)
      end
    end
  end
end
