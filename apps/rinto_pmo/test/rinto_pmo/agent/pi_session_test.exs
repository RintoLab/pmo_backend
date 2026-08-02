defmodule RintoPMO.Agent.PiSessionTest do
  use ExUnit.Case, async: true

  alias RintoPMO.Agent.PiSession
  alias RintoPMO.OSProcess

  @moduletag :capture_log
  @moduletag :tmp_dir

  # test/support/fake_pi.sh stands in for `pi --mode rpc`. It sources its
  # behaviour from its last argument, so the JSONL protocol can be faked without
  # a real pi and without any model call.
  #
  # The behaviour is a sourced data file rather than an executable of its own
  # because macOS scans a newly created executable on its first execve -- ~300ms,
  # serialised system-wide -- which a per-test script would charge to every test.
  @fake_pi Path.expand("../../support/fake_pi.sh", __DIR__)

  defp fake_pi(tmp_dir, body) do
    path = Path.join(tmp_dir, "behaviour-#{System.unique_integer([:positive])}.sh")
    File.write!(path, body)
    [executable: @fake_pi, extra_args: [path]]
  end

  # Echoes back a response for every command it reads, preserving the id.
  defp echo_pi(tmp_dir) do
    fake_pi(tmp_dir, """
    while IFS= read -r line; do
      id=$(printf '%s' "$line" | sed 's/.*"id":"\\([^"]*\\)".*/\\1/')
      printf '{"type":"response","command":"echo","id":"%s","success":true,"data":{"ok":true}}\\n' "$id"
    done
    """)
  end

  defp start_session!(opts) do
    assert {:ok, pid} = PiSession.Supervisor.start_session(opts)
    on_exit(fn -> PiSession.close(pid) end)
    pid
  end

  describe "command/3" do
    test "correlates a response by id", %{tmp_dir: tmp_dir} do
      session = start_session!(echo_pi(tmp_dir))

      assert {:ok, %{"success" => true, "data" => %{"ok" => true}}} =
               PiSession.command(session, %{"type" => "ping"})
    end

    test "keeps a caller-supplied id", %{tmp_dir: tmp_dir} do
      session = start_session!(echo_pi(tmp_dir))

      assert {:ok, %{"id" => "mine-1"}} =
               PiSession.command(session, %{"type" => "ping", "id" => "mine-1"})
    end

    # pi dispatches input lines without awaiting them, so responses can come
    # back in any order; only the id ties a reply to its caller.
    #
    # The fake always answers the second line it read before the first, so the
    # replies are reversed no matter which command won the race to be written.
    # Asserting on the echoed id rather than on arrival order keeps this
    # deterministic under load.
    test "handles concurrent commands whose responses arrive out of order", %{tmp_dir: tmp_dir} do
      pi =
        fake_pi(tmp_dir, """
        read -r first
        read -r second
        fid=$(printf '%s' "$first" | sed 's/.*"id":"\\([^"]*\\)".*/\\1/')
        sid=$(printf '%s' "$second" | sed 's/.*"id":"\\([^"]*\\)".*/\\1/')
        printf '{"type":"response","id":"%s","success":true,"data":{}}\\n' "$sid"
        printf '{"type":"response","id":"%s","success":true,"data":{}}\\n' "$fid"
        sleep 30
        """)

      session = start_session!(pi)

      alpha = Task.async(fn -> PiSession.command(session, %{"type" => "a", "id" => "alpha"}) end)
      beta = Task.async(fn -> PiSession.command(session, %{"type" => "b", "id" => "beta"}) end)

      assert {:ok, %{"id" => "alpha"}} = Task.await(alpha, 5_000)
      assert {:ok, %{"id" => "beta"}} = Task.await(beta, 5_000)
    end

    test "reports a session that is not running" do
      assert {:error, :not_found} = PiSession.command("no-such-session", %{"type" => "ping"})
    end
  end

  describe "suspension" do
    # The fake asks a question and then blocks. Nothing may expire it.
    defp asking_pi(tmp_dir, method_json) do
      fake_pi(tmp_dir, """
      read -r line
      printf '%s\\n' '#{method_json}'
      read -r answer
      printf '{"type":"response","id":"after","success":true,"data":{"answer":%s}}\\n' "$(printf '%s' "$answer" | sed 's/.*"value":"\\([^"]*\\)".*/\\"\\1\\"/')"
      sleep 30
      """)
    end

    test "parks a blocking request and broadcasts it", %{tmp_dir: tmp_dir} do
      json =
        ~s({"type":"extension_ui_request","id":"ui-1","method":"select","title":"Pick","options":["A","B"]})

      session = start_session!(asking_pi(tmp_dir, json))
      {:ok, %{id: session_id}} = {:ok, %{id: session_id(session)}}
      :ok = PiSession.subscribe(session_id)

      Task.start(fn -> PiSession.command(session, %{"type" => "go"}) end)

      assert_receive {:pi_session, ^session_id, {:ui_request, request}}, 5_000
      assert request["method"] == "select"
      assert request["options"] == ["A", "B"]

      assert {:ok, [^request]} = PiSession.pending_ui(session)
    end

    # The whole point: no timer anywhere may resolve this on the user's behalf.
    test "leaves a question parked indefinitely", %{tmp_dir: tmp_dir} do
      json =
        ~s({"type":"extension_ui_request","id":"ui-1","method":"confirm","title":"Sure?","message":"m"})

      session = start_session!(asking_pi(tmp_dir, json))
      Task.start(fn -> PiSession.command(session, %{"type" => "go"}) end)

      assert eventually(fn -> match?({:ok, [_one]}, PiSession.pending_ui(session)) end)

      # Any wait is arbitrary -- no wait proves the absence of a timer. This one
      # only has to outlast the timers the session does have (drain, 25ms), so
      # it is kept an order of magnitude above that rather than at a full second.
      Process.sleep(300)

      assert {:ok, [%{"id" => "ui-1"}]} = PiSession.pending_ui(session)
      assert PiSession.alive?(session)
    end

    test "answering releases what was blocked and clears the parked entry", %{tmp_dir: tmp_dir} do
      json =
        ~s({"type":"extension_ui_request","id":"ui-1","method":"select","title":"Pick","options":["A","B"]})

      session = start_session!(asking_pi(tmp_dir, json))
      session_id = session_id(session)
      :ok = PiSession.subscribe(session_id)

      Task.start(fn -> PiSession.command(session, %{"type" => "go", "id" => "go"}) end)
      assert_receive {:pi_session, ^session_id, {:ui_request, _request}}, 5_000

      assert {:ok, _request} = PiSession.answer(session, "ui-1", {:value, "B"})
      assert_receive {:pi_session, ^session_id, {:ui_resolved, "ui-1"}}, 5_000

      assert {:ok, []} = PiSession.pending_ui(session)

      # The fake echoes the answer back, proving pi-side received it.
      assert {:ok, response} = PiSession.command(session, %{"type" => "noop", "id" => "after"})
      assert response["data"]["answer"] == "B"
    end

    test "rejects an answer for an unknown question", %{tmp_dir: tmp_dir} do
      session = start_session!(echo_pi(tmp_dir))

      assert {:error, :unknown_ui_request} = PiSession.answer(session, "nope", :cancelled)
    end

    test "ignores fire-and-forget UI frames", %{tmp_dir: tmp_dir} do
      pi =
        fake_pi(tmp_dir, """
        read -r line
        printf '%s\\n' '{"type":"extension_ui_request","id":"u1","method":"setStatus","statusKey":"k","statusText":"t"}'
        printf '%s\\n' '{"type":"extension_ui_request","id":"u2","method":"setWidget","widgetKey":"k"}'
        printf '%s\\n' '{"type":"response","id":"go","success":true,"data":{}}'
        sleep 30
        """)

      session = start_session!(pi)

      assert {:ok, _response} = PiSession.command(session, %{"type" => "go", "id" => "go"})
      assert {:ok, []} = PiSession.pending_ui(session)
    end
  end

  describe "events" do
    test "broadcasts conversation frames and drops everything else", %{tmp_dir: tmp_dir} do
      pi =
        fake_pi(tmp_dir, """
        read -r line
        printf '%s\\n' '{"type":"extension_ui_request","id":"u1","method":"setStatus"}'
        printf '%s\\n' '{"type":"some_future_frame_type","payload":1}'
        printf '%s\\n' '{"type":"turn_end","message":{"role":"assistant"}}'
        printf '%s\\n' '{"type":"response","id":"go","success":true,"data":{}}'
        sleep 30
        """)

      session = start_session!(pi)
      session_id = session_id(session)
      :ok = PiSession.subscribe(session_id)

      assert {:ok, _response} = PiSession.command(session, %{"type" => "go", "id" => "go"})

      assert_receive {:pi_session, ^session_id, {:event, %{"type" => "turn_end"}}}, 5_000
      refute_received {:pi_session, ^session_id, {:event, %{"type" => "some_future_frame_type"}}}
      refute_received {:pi_session, ^session_id, {:event, %{"type" => "extension_ui_request"}}}
    end

    test "reports the pi process exiting and fails in-flight commands", %{tmp_dir: tmp_dir} do
      pi = fake_pi(tmp_dir, "read -r line\nexit 4\n")

      session = start_session!(pi)
      session_id = session_id(session)
      :ok = PiSession.subscribe(session_id)

      assert {:error, {:exit, {:exit, 4}}} = PiSession.command(session, %{"type" => "go"})
      assert_receive {:pi_session, ^session_id, {:exit, {:exit, 4}}}, 5_000
    end
  end

  describe "management" do
    test "info/1 snapshots a session", %{tmp_dir: tmp_dir} do
      session = start_session!(echo_pi(tmp_dir))

      assert {:ok, info} = PiSession.info(session)
      assert info.id == session_id(session)
      assert info.pid == session
      assert is_integer(info.os_pid)
      assert %DateTime{} = info.started_at
      assert info.idle_ms >= 0
      refute info.awaiting_input?
      assert info.pending_ui == []
      assert info.in_flight_commands == 0
    end

    test "info/1 reports a session blocked on a human", %{tmp_dir: tmp_dir} do
      json =
        ~s({"type":"extension_ui_request","id":"ui-1","method":"confirm","title":"Sure?","message":"m"})

      session = start_session!(asking_pi(tmp_dir, json))
      Task.start(fn -> PiSession.command(session, %{"type" => "go"}, :infinity) end)

      assert eventually(fn ->
               match?({:ok, %{awaiting_input?: true}}, PiSession.info(session))
             end)

      assert {:ok, info} = PiSession.info(session)
      assert [%{"id" => "ui-1"}] = info.pending_ui
      assert info.in_flight_commands == 1
    end

    # The snapshot must stay available precisely when a session is stuck; that
    # is when an operator needs it.
    test "info/1 answers while a command is parked", %{tmp_dir: tmp_dir} do
      json =
        ~s({"type":"extension_ui_request","id":"ui-1","method":"select","title":"T","options":["A"]})

      session = start_session!(asking_pi(tmp_dir, json))
      Task.start(fn -> PiSession.command(session, %{"type" => "go"}, :infinity) end)
      assert eventually(fn -> match?({:ok, [_one]}, PiSession.pending_ui(session)) end)

      assert {:ok, _info} = PiSession.info(session)
    end

    test "idle_ms grows while nothing happens", %{tmp_dir: tmp_dir} do
      session = start_session!(echo_pi(tmp_dir))
      {:ok, first} = PiSession.info(session)

      Process.sleep(120)
      {:ok, second} = PiSession.info(session)
      assert second.idle_ms > first.idle_ms

      # Talking to pi resets it.
      {:ok, _response} = PiSession.command(session, %{"type" => "ping"})
      {:ok, third} = PiSession.info(session)
      assert third.idle_ms < second.idle_ms
    end

    # Asserting a relative increase rather than an exact count: the registry is
    # global, so an exact number would depend on what else is running.
    test "count/0 and list/0 track running sessions", %{tmp_dir: tmp_dir} do
      before_count = PiSession.Supervisor.count()

      session = start_session!(echo_pi(tmp_dir))
      id = session_id(session)

      assert PiSession.Supervisor.count() > before_count
      assert id in PiSession.Supervisor.list()

      :ok = PiSession.close(session)

      assert eventually(fn -> id not in PiSession.Supervisor.list() end)
    end

    test "list_info/0 includes running sessions", %{tmp_dir: tmp_dir} do
      session = start_session!(echo_pi(tmp_dir))
      id = session_id(session)

      assert Enum.any?(PiSession.Supervisor.list_info(), &(&1.id == id))
    end

    test "awaiting_input/0 surfaces only the blocked sessions", %{tmp_dir: tmp_dir} do
      json =
        ~s({"type":"extension_ui_request","id":"ui-1","method":"confirm","title":"T","message":"m"})

      idle = start_session!(echo_pi(tmp_dir))
      blocked = start_session!(asking_pi(tmp_dir, json))

      Task.start(fn -> PiSession.command(blocked, %{"type" => "go"}, :infinity) end)
      assert eventually(fn -> match?({:ok, [_one]}, PiSession.pending_ui(blocked)) end)

      waiting_ids = Enum.map(PiSession.Supervisor.awaiting_input(), & &1.id)

      assert session_id(blocked) in waiting_ids
      refute session_id(idle) in waiting_ids
    end

    # close_all/0 is global by design, so this asserts only on its own sessions
    # rather than on an empty registry, which anything else running would break.
    test "close_all/0 stops every session", %{tmp_dir: tmp_dir} do
      first = start_session!(echo_pi(tmp_dir))
      second = start_session!(echo_pi(tmp_dir))

      assert PiSession.Supervisor.close_all() >= 2

      refute PiSession.alive?(first)
      refute PiSession.alive?(second)
    end
  end

  describe "lifecycle" do
    test "close/1 reaps the pi process", %{tmp_dir: tmp_dir} do
      session = start_session!(fake_pi(tmp_dir, "sleep 300\n"))
      session_id = session_id(session)
      {:ok, %{os_pid: os_pid}} = OSProcess.info("pi-session-#{session_id}")

      assert :ok = PiSession.close(session)

      refute os_pid in :exec.which_children()
      refute PiSession.alive?(session_id)
    end

    test "is not restarted after a crash", %{tmp_dir: tmp_dir} do
      session = start_session!(fake_pi(tmp_dir, "sleep 300\n"))
      session_id = session_id(session)
      ref = Process.monitor(session)

      Process.exit(session, :kill)
      assert_receive {:DOWN, ^ref, :process, _pid, _reason}, 5_000

      assert eventually(fn -> session_id not in PiSession.Supervisor.list() end)
    end

    test "removes a session directory it created", %{tmp_dir: tmp_dir} do
      session = start_session!(fake_pi(tmp_dir, "sleep 300\n"))
      {:ok, dir} = {:ok, :sys.get_state(session).session_dir}
      assert File.dir?(dir)

      assert :ok = PiSession.close(session)
      refute File.exists?(dir)
    end

    test "reports a missing pi executable" do
      assert {:error, :pi_not_found} =
               PiSession.Supervisor.start_session(
                 executable: "pi-does-not-exist-#{System.unique_integer([:positive])}"
               )
    end
  end

  defp session_id(session), do: :sys.get_state(session).id

  defp eventually(fun, attempts \\ 100)
  defp eventually(_fun, 0), do: false

  defp eventually(fun, attempts) do
    if fun.() do
      true
    else
      Process.sleep(20)
      eventually(fun, attempts - 1)
    end
  end
end
