defmodule RintoPMOWeb.PiSessionChannelTest do
  use RintoPMOWeb.ChannelCase, async: true

  alias RintoPMO.Agent.PiSession
  alias RintoPMOWeb.PiSocket

  @moduletag :capture_log
  @moduletag :tmp_dir

  # test/support/fake_pi.sh stands in for `pi --mode rpc`, so the channel is
  # exercised without a real pi and without any model call. It sources its
  # behaviour from its last argument.
  #
  # The behaviour is a sourced data file rather than an executable of its own
  # because macOS scans a newly created executable on its first execve -- ~300ms,
  # serialised system-wide -- which a per-test script would charge to every test.
  @fake_pi Path.expand("../../support/fake_pi.sh", __DIR__)
  @fake_pi_echo Path.expand("../../support/fake_pi_echo.sh", __DIR__)

  defp fake_pi(tmp_dir, body) do
    path = Path.join(tmp_dir, "behaviour-#{System.unique_integer([:positive])}.sh")
    File.write!(path, body)
    [executable: @fake_pi, extra_args: [path]]
  end

  defp echo_pi(tmp_dir) do
    fake_pi(tmp_dir, """
    while IFS= read -r line; do
      id=$(printf '%s' "$line" | sed 's/.*"id":"\\([^"]*\\)".*/\\1/')
      printf '{"type":"response","id":"%s","success":true,"data":{"ok":true}}\\n' "$id"
    done
    """)
  end

  # Asks one question, then answers the command once released.
  defp asking_pi(tmp_dir) do
    fake_pi(tmp_dir, """
    read -r line
    printf '%s\\n' '{"type":"extension_ui_request","id":"ui-1","method":"select","title":"Pick","options":["A","B"]}'
    read -r answer
    printf '{"type":"turn_end","message":{"role":"assistant"}}\\n'
    id=$(printf '%s' "$line" | sed 's/.*"id":"\\([^"]*\\)".*/\\1/')
    printf '{"type":"response","id":"%s","success":true,"data":{"picked":%s}}\\n' "$id" "$(printf '%s' "$answer" | sed 's/.*"value":"\\([^"]*\\)".*/\\"\\1\\"/')"
    sleep 30
    """)
  end

  defp start_session!(opts) do
    assert {:ok, pid} = PiSession.Supervisor.start_session(opts)
    on_exit(fn -> PiSession.close(pid) end)
    :sys.get_state(pid).id
  end

  defp connect_socket do
    {:ok, socket} = Phoenix.ChannelTest.connect(PiSocket, %{})
    socket
  end

  defp join!(session_id, params \\ %{}) do
    {:ok, _reply, socket} =
      subscribe_and_join(connect_socket(), "pi_session:#{session_id}", params)

    socket
  end

  describe "join" do
    test "attaches to a running session", %{tmp_dir: tmp_dir} do
      session_id = start_session!(echo_pi(tmp_dir))

      assert {:ok, _reply, _socket} =
               subscribe_and_join(connect_socket(), "pi_session:#{session_id}", %{})
    end

    test "refuses an unknown session" do
      assert {:error, %{reason: "not_found"}} =
               subscribe_and_join(connect_socket(), "pi_session:nope", %{})
    end

    test "creates a session on request" do
      # `create` builds the argv itself, so it cannot pass a behaviour file --
      # point it at the fake that has echoing baked in.
      previous = Application.get_env(:rinto_pmo, :pi_executable)
      Application.put_env(:rinto_pmo, :pi_executable, @fake_pi_echo)
      on_exit(fn -> Application.put_env(:rinto_pmo, :pi_executable, previous) end)

      session_id = "channel-created-#{System.unique_integer([:positive])}"
      on_exit(fn -> PiSession.close(session_id) end)

      assert {:ok, _reply, _socket} =
               subscribe_and_join(connect_socket(), "pi_session:#{session_id}", %{
                 "create" => true
               })

      assert PiSession.alive?(session_id)
    end

    # A client that arrives after a notification must still see the question.
    test "pushes questions parked before the client connected", %{tmp_dir: tmp_dir} do
      session_id = start_session!(asking_pi(tmp_dir))

      Task.start(fn -> PiSession.command(session_id, %{"type" => "prompt"}, :infinity) end)
      assert eventually(fn -> match?({:ok, [_one]}, PiSession.pending_ui(session_id)) end)

      join!(session_id)

      assert_push "pending_ui", %{pending_ui: [%{"id" => "ui-1", "method" => "select"}]}, 5_000
    end

    test "pushes an empty list when nothing is parked", %{tmp_dir: tmp_dir} do
      join!(start_session!(echo_pi(tmp_dir)))

      assert_push "pending_ui", %{pending_ui: []}, 5_000
    end
  end

  describe "commands" do
    test "replies to a raw command", %{tmp_dir: tmp_dir} do
      socket = join!(start_session!(echo_pi(tmp_dir)))

      ref = push(socket, "command", %{"type" => "get_state"})
      assert_reply ref, :ok, %{"data" => %{"ok" => true}}, 5_000
    end

    test "replies to a prompt", %{tmp_dir: tmp_dir} do
      socket = join!(start_session!(echo_pi(tmp_dir)))

      ref = push(socket, "prompt", %{"message" => "hello"})
      assert_reply ref, :ok, %{"success" => true}, 5_000
    end

    test "rejects an unknown event", %{tmp_dir: tmp_dir} do
      socket = join!(start_session!(echo_pi(tmp_dir)))

      ref = push(socket, "nonsense", %{})
      assert_reply ref, :error, %{reason: "unknown_event"}, 5_000
    end
  end

  describe "suspension" do
    test "pushes a question and answering releases the command", %{tmp_dir: tmp_dir} do
      socket = join!(start_session!(asking_pi(tmp_dir)))
      assert_push "pending_ui", %{pending_ui: []}, 5_000

      ref = push(socket, "prompt", %{"message" => "go"})

      assert_push "ui_request", %{"id" => "ui-1", "options" => ["A", "B"]}, 5_000

      answer_ref = push(socket, "answer", %{"ui_id" => "ui-1", "value" => "B"})
      assert_reply answer_ref, :ok, _payload, 5_000

      assert_push "ui_resolved", %{ui_id: "ui-1"}, 5_000
      assert_push "event", %{"type" => "turn_end"}, 5_000

      # The prompt only now completes, carrying the answer through pi.
      assert_reply ref, :ok, %{"data" => %{"picked" => "B"}}, 5_000
    end

    # The command runs off the channel process precisely so this works: a
    # blocked prompt must not block the channel that has to release it.
    test "the channel stays responsive while a command is parked", %{tmp_dir: tmp_dir} do
      socket = join!(start_session!(asking_pi(tmp_dir)))

      push(socket, "prompt", %{"message" => "go"})
      assert_push "ui_request", %{"id" => "ui-1"}, 5_000

      ref = push(socket, "pending_ui", %{})
      assert_reply ref, :ok, %{pending_ui: [%{"id" => "ui-1"}]}, 5_000
    end

    test "cancelling is a valid answer", %{tmp_dir: tmp_dir} do
      socket = join!(start_session!(asking_pi(tmp_dir)))

      push(socket, "prompt", %{"message" => "go"})
      assert_push "ui_request", %{"id" => "ui-1"}, 5_000

      ref = push(socket, "answer", %{"ui_id" => "ui-1", "cancelled" => true})
      assert_reply ref, :ok, _payload, 5_000
    end

    test "rejects a malformed answer", %{tmp_dir: tmp_dir} do
      socket = join!(start_session!(echo_pi(tmp_dir)))

      ref = push(socket, "answer", %{"ui_id" => "ui-1", "nonsense" => 1})
      assert_reply ref, :error, %{reason: "invalid_answer"}, 5_000
    end

    test "rejects an answer to an unknown question", %{tmp_dir: tmp_dir} do
      socket = join!(start_session!(echo_pi(tmp_dir)))

      ref = push(socket, "answer", %{"ui_id" => "nope", "value" => "x"})
      assert_reply ref, :error, %{reason: "unknown_ui_request"}, 5_000
    end
  end

  describe "lifecycle" do
    # A session outlives the browser tab; that is what lets a question wait.
    test "leaving does not end the session", %{tmp_dir: tmp_dir} do
      session_id = start_session!(echo_pi(tmp_dir))
      socket = join!(session_id)

      # ChannelTest links the channel to the test process; the shutdown that
      # leaving triggers would otherwise take the test down with it.
      Process.unlink(socket.channel_pid)
      ref = leave(socket)
      assert_reply ref, :ok, _payload, 5_000

      assert PiSession.alive?(session_id)
    end

    test "close ends the session", %{tmp_dir: tmp_dir} do
      session_id = start_session!(echo_pi(tmp_dir))
      socket = join!(session_id)

      ref = push(socket, "close", %{})
      assert_reply ref, :ok, %{closed: true}, 5_000

      refute PiSession.alive?(session_id)
    end

    test "pushes an exit and stops when pi dies", %{tmp_dir: tmp_dir} do
      socket = join!(start_session!(fake_pi(tmp_dir, "read -r line\nexit 7\n")))

      push(socket, "command", %{"type" => "go"})

      assert_push "exit", %{status: status}, 5_000
      assert status =~ "7"
    end
  end

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
