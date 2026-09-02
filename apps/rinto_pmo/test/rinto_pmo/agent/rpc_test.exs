defmodule RintoPMO.Agent.RpcTest do
  @moduledoc """
  Covers this module's own protocol handling -- correlating a response by id,
  ignoring everything else, timing out, cleaning up -- with `OSProcess` mocked.

  Nothing here spawns a process. That is the point: driving a real child costs
  seconds -- almost all of it erlexec's one-time port startup, magnified by
  running tests concurrently -- and none of it exercises `Rpc`. Output is
  delivered by sending the owner the same `{:os_process, id, event}` messages
  `OSProcess` would.

  That makes the message shape an assumption here, and one a mock can never
  falsify. It is pinned elsewhere: `RintoPMO.OSProcessTest` asserts the shape
  directly, and `RintoPMO.Agent.PiSessionTest` drives real child processes
  through the same events. Both would fail before this module noticed.

  Each layer mocks only the one below it, so `RintoPMO.Agent.Models` mocks this
  module and never reaches `OSProcess` at all.
  """

  use ExUnit.Case, async: true

  import Hammox

  alias RintoPMO.Agent.PiInstallation
  alias RintoPMO.Agent.Rpc

  setup :verify_on_exit!

  @command %{"type" => "ping", "id" => "fixed-1"}

  defp response(id), do: ~s({"type":"response","id":"#{id}","success":true,"data":{"ok":true}})

  # Accepts the spawn and hands back the id Rpc generated, so the test can
  # address the instance exactly as OSProcess would.
  defp expect_open(test_pid \\ self()) do
    expect(RintoPMO.OSProcessMock, :start, fn opts ->
      send(test_pid, {:opened, Keyword.fetch!(opts, :id), opts})
      {:ok, spawn(fn -> :ok end)}
    end)
  end

  # Mirrors the real stop: tearing an instance down delivers a final exit event
  # to the owner, which is what lets `close/1` stop draining immediately.
  defp expect_stop do
    expect(RintoPMO.OSProcessMock, :stop, fn ref ->
      send(self(), {:os_process, ref, {:exit, {:stopped, :normal}}})
      :ok
    end)
  end

  # The child already exited, so the instance is gone and emits nothing more.
  defp expect_stop_already_gone do
    expect(RintoPMO.OSProcessMock, :stop, fn _ref -> {:error, :not_found} end)
  end

  # Replays what the child would have written, in order, once the command has
  # been sent. Rpc reads these from its own mailbox.
  defp expect_send_emitting(lines) do
    expect(RintoPMO.OSProcessMock, :send, fn id, _data ->
      Enum.each(lines, fn
        {:exit, status} -> send(self(), {:os_process, id, {:exit, status}})
        line -> send(self(), {:os_process, id, {:stdout, line}})
      end)

      :ok
    end)
  end

  describe "request/2" do
    test "returns the response matching the command id" do
      expect_open()
      expect_send_emitting([response("fixed-1")])
      expect_stop()

      assert {:ok, %{"success" => true, "data" => %{"ok" => true}}} =
               Rpc.request(@command)
    end

    test "skips frames that are not the matching response" do
      expect_open()

      expect_send_emitting([
        ~s({"type":"event","name":"startup"}),
        "not json at all",
        ~s({"type":"extension_ui_request","id":"ui-1","method":"setStatus"}),
        response("some-other-id"),
        response("fixed-1")
      ])

      expect_stop()

      assert {:ok, %{"id" => "fixed-1"}} = Rpc.request(@command)
    end

    test "times out when no matching response arrives" do
      expect_open()
      expect_send_emitting([response("some-other-id")])
      expect_stop()

      assert {:error, :timeout} = Rpc.request(@command, timeout: 50)
    end

    test "reports the exit code when the child dies first" do
      expect_open()
      expect_send_emitting([{:exit, {:exit, 9}}])
      expect_stop_already_gone()

      assert {:error, {:pi_exit, 9}} = Rpc.request(@command)
    end

    test "distinguishes a teardown from a clean exit" do
      expect_open()
      expect_send_emitting([{:exit, {:stopped, :normal}}])
      expect_stop_already_gone()

      assert {:error, {:pi_died, {:stopped, :normal}}} = Rpc.request(@command)
    end

    test "reports a failure to write the command" do
      expect_open()
      expect(RintoPMO.OSProcessMock, :send, fn _id, _data -> {:error, :not_found} end)
      expect_stop()

      assert {:error, {:send_failed, :not_found}} = Rpc.request(@command)
    end

    test "reports a missing executable" do
      expect(RintoPMO.OSProcessMock, :start, fn _opts ->
        {:error, {:executable_not_found, "pi"}}
      end)

      assert {:error, :pi_not_found} = Rpc.request(@command)
    end

    test "reports any other spawn failure distinctly" do
      expect(RintoPMO.OSProcessMock, :start, fn _opts -> {:error, {:spawn_failed, :eacces}} end)

      assert {:error, {:spawn_failed, {:spawn_failed, :eacces}}} =
               Rpc.request(@command)
    end

    test "generates a command id when the caller supplies none" do
      expect_open()

      expect(RintoPMO.OSProcessMock, :send, fn id, data ->
        assert %{"id" => generated, "type" => "noop"} = JSON.decode!(data)
        assert is_binary(generated)
        send(self(), {:os_process, id, {:stdout, response(generated)}})
        :ok
      end)

      expect_stop()

      assert {:ok, _response} = Rpc.request(%{"type" => "noop"})
    end

    test "accepts atom keys in the command" do
      expect_open()

      expect(RintoPMO.OSProcessMock, :send, fn id, data ->
        assert %{"type" => "ping", "id" => "atom-1"} = JSON.decode!(data)
        send(self(), {:os_process, id, {:stdout, response("atom-1")}})
        :ok
      end)

      expect_stop()

      assert {:ok, _response} = Rpc.request(%{type: "ping", id: "atom-1"})
    end

    # request/2 runs in the caller's process, which in production is a
    # GenServer; a leftover frame would surface there as an unexpected message.
    test "leaves no os_process messages in the caller's mailbox" do
      expect_open()

      expect_send_emitting([
        response("fixed-1"),
        "trailing chatter after the response",
        {:exit, {:exit, 0}}
      ])

      expect_stop_already_gone()

      assert {:ok, _response} = Rpc.request(@command)

      refute_received {:os_process, _id, _event}
    end
  end

  describe "open/1" do
    test "runs pi in rpc mode against a session directory" do
      expect_open()
      expect_stop()

      assert {:ok, rpc} = Rpc.open(executable: "/bin/sh")
      assert_received {:opened, _id, opts}

      assert Keyword.fetch!(opts, :cmd) == "/bin/sh"
      assert Keyword.fetch!(opts, :framing) == :lines
      # pi's startup chatter would otherwise pollute discovery output.
      assert Keyword.fetch!(opts, :stderr) == :discard

      environment = Keyword.fetch!(opts, :env)
      assert {"HOME", System.get_env("HOME")} in environment
      assert {"PI_CODING_AGENT_DIR", PiInstallation.agent_dir()} in environment

      args = Keyword.fetch!(opts, :args)
      assert "--mode" in args and "rpc" in args
      assert "--no-session" in args
      assert rpc.session_dir in args

      Rpc.close(rpc)
    end

    test "passes --offline only when asked" do
      expect_open()
      expect_stop()

      assert {:ok, rpc} = Rpc.open(executable: "/bin/sh", offline: true)
      assert_received {:opened, _id, opts}
      assert "--offline" in Keyword.fetch!(opts, :args)

      Rpc.close(rpc)
    end

    test "removes the directory it generated when the spawn fails" do
      expect(RintoPMO.OSProcessMock, :start, fn opts ->
        # The directory exists at spawn time; the failure path must clean it up.
        assert opts |> Keyword.fetch!(:args) |> Enum.any?(&File.dir?/1)
        {:error, {:executable_not_found, "pi"}}
      end)

      assert {:error, :pi_not_found} = Rpc.open(executable: "nope")
    end
  end

  describe "close/1" do
    test "removes a session directory it created" do
      expect_open()
      expect_stop()

      assert {:ok, rpc} = Rpc.open(executable: "/bin/sh")
      assert File.dir?(rpc.session_dir)

      assert :ok = Rpc.close(rpc)
      refute File.exists?(rpc.session_dir)
    end

    test "keeps a session directory the caller supplied", %{} do
      dir = Path.join(System.tmp_dir!(), "rpc-supplied-#{System.unique_integer([:positive])}")
      on_exit(fn -> File.rm_rf(dir) end)

      expect_open()
      expect_stop()

      assert {:ok, rpc} = Rpc.open(executable: "/bin/sh", session_dir: dir)
      assert :ok = Rpc.close(rpc)

      assert File.dir?(dir)
    end
  end
end
