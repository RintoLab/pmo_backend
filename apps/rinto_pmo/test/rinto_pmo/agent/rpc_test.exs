defmodule RintoPMO.Agent.RpcTest do
  use ExUnit.Case, async: true

  alias RintoPMO.Agent.Rpc
  alias RintoPMO.OSProcess

  @moduletag :capture_log
  @moduletag :tmp_dir

  # A stand-in for `pi --mode rpc`: it speaks just enough of the protocol to
  # exercise the transport without depending on a real pi being installed.
  defp fake_pi(tmp_dir, body) do
    path = Path.join(tmp_dir, "fake-pi-#{System.unique_integer([:positive])}")
    File.write!(path, "#!/bin/sh\n" <> body)
    File.chmod!(path, 0o755)
    path
  end

  defp response(id), do: ~s({"type":"response","id":"#{id}","success":true,"data":{"ok":true}})

  defp request(path, opts \\ []) do
    Rpc.request(
      %{"type" => "ping", "id" => "fixed-1"},
      Keyword.merge([executable: path, timeout: 2_000], opts)
    )
  end

  describe "request/2" do
    test "returns the response matching the command id", %{tmp_dir: tmp_dir} do
      path = fake_pi(tmp_dir, "read -r line\nprintf '%s\\n' '#{response("fixed-1")}'\n")

      assert {:ok, %{"success" => true, "data" => %{"ok" => true}}} = request(path)
    end

    test "skips frames that are not the matching response", %{tmp_dir: tmp_dir} do
      body = """
      read -r line
      printf '%s\\n' '{"type":"event","name":"startup"}'
      printf '%s\\n' 'not json at all'
      printf '%s\\n' '#{response("some-other-id")}'
      printf '%s\\n' '#{response("fixed-1")}'
      """

      assert {:ok, %{"id" => "fixed-1"}} = request(fake_pi(tmp_dir, body))
    end

    test "discards whatever the child writes to stderr", %{tmp_dir: tmp_dir} do
      body = """
      printf 'noisy warning\\n' 1>&2
      read -r line
      printf '%s\\n' '#{response("fixed-1")}'
      """

      assert {:ok, _response} = request(fake_pi(tmp_dir, body))
    end

    test "times out when no matching response arrives", %{tmp_dir: tmp_dir} do
      path = fake_pi(tmp_dir, "read -r line\nsleep 30\n")

      assert {:error, :timeout} = request(path, timeout: 200)
    end

    test "reports the exit code when the child dies first", %{tmp_dir: tmp_dir} do
      path = fake_pi(tmp_dir, "exit 9\n")

      assert {:error, {:pi_exit, 9}} = request(path)
    end

    test "reports a missing executable" do
      assert {:error, :pi_not_found} =
               request("pi-binary-that-does-not-exist-#{System.unique_integer([:positive])}")
    end

    # request/2 runs in the caller's process, which in production is a
    # GenServer; a leftover frame would surface there as an unexpected message.
    test "leaves no os_process messages in the caller's mailbox", %{tmp_dir: tmp_dir} do
      body = """
      read -r line
      printf '%s\\n' '#{response("fixed-1")}'
      printf '%s\\n' 'trailing chatter after the response'
      sleep 30
      """

      assert {:ok, _response} = request(fake_pi(tmp_dir, body))

      refute_received {:os_process, _id, _event}
    end
  end

  describe "close/1" do
    test "reaps a child that would otherwise outlive the request", %{tmp_dir: tmp_dir} do
      path = fake_pi(tmp_dir, "sleep 300\n")

      assert {:ok, rpc} = Rpc.open(executable: path)
      assert {:ok, %{os_pid: os_pid}} = OSProcess.info(rpc.os_process)

      assert :ok = Rpc.close(rpc)

      refute os_pid in :exec.which_children()
      refute OSProcess.running?(rpc.os_process)
    end

    test "removes a session directory it created", %{tmp_dir: tmp_dir} do
      path = fake_pi(tmp_dir, "sleep 30\n")

      assert {:ok, rpc} = Rpc.open(executable: path)
      assert File.dir?(rpc.session_dir)

      assert :ok = Rpc.close(rpc)
      refute File.exists?(rpc.session_dir)
    end

    test "keeps a session directory the caller supplied", %{tmp_dir: tmp_dir} do
      path = fake_pi(tmp_dir, "sleep 30\n")
      session_dir = Path.join(tmp_dir, "session")

      assert {:ok, rpc} =
               Rpc.open(executable: path, session_dir: session_dir)

      assert :ok = Rpc.close(rpc)
      assert File.dir?(session_dir)
    end
  end

  describe "open/1" do
    test "does not leave a session directory behind when the spawn fails" do
      before = tmp_session_dirs()

      assert {:error, :pi_not_found} =
               Rpc.open(executable: "pi-binary-that-does-not-exist-#{System.unique_integer()}")

      assert tmp_session_dirs() == before
    end
  end

  defp tmp_session_dirs do
    System.tmp_dir!()
    |> Path.join("rinto-pmo-pi-rpc-*")
    |> Path.wildcard()
    |> MapSet.new()
  end
end
