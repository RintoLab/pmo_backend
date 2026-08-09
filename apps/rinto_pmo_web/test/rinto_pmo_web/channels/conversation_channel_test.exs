defmodule RintoPMOWeb.ConversationChannelTest do
  # Not async: the module points `:pi_executable` at a stand-in for the whole
  # run, which is application-wide, and the auto-heating path builds its own
  # argv so it cannot be handed an executable per call.
  use RintoPMOWeb.ChannelCase, async: false

  alias RintoPMO.Agent.PiSession
  alias RintoPMO.Agent.TitleGeneratorMock
  alias RintoPMO.Attachments
  alias RintoPMO.AttachmentsMock
  alias RintoPMO.Conversations
  alias RintoPMO.Conversations.Titles
  alias RintoPMO.ConversationsMock
  alias RintoPMO.DocumentsMock
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

  setup do
    # Heating happens inside the channel, which builds pi's argv itself, so the
    # only way to keep a real pi out of these tests is the application setting.
    previous = Application.get_env(:rinto_pmo, :pi_executable)
    Application.put_env(:rinto_pmo, :pi_executable, @fake_pi_echo)
    on_exit(fn -> Application.put_env(:rinto_pmo, :pi_executable, previous) end)

    # The real context: these tests are about what the channel does to a topic,
    # and mocking the thing being changed would only test the mock.
    stub_with(ConversationsMock, Conversations)
    stub_with(AttachmentsMock, Attachments)
    :ok
  end

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

  # Echoes like echo_pi but also records every command line it received, so a
  # test can assert on what actually reached pi rather than on the reply.
  #
  # The capture path is quoted: ExUnit builds `tmp_dir` from the test name, so
  # any test whose name contains a quote or a space would otherwise produce a
  # script that will not parse.
  defp capturing_pi(tmp_dir, capture_path) do
    fake_pi(tmp_dir, """
    while IFS= read -r line; do
      printf '%s\\n' "$line" >> "#{capture_path}"
      id=$(printf '%s' "$line" | sed 's/.*"id":"\\([^"]*\\)".*/\\1/')
      printf '{"type":"response","id":"%s","success":true,"data":{"ok":true}}\\n' "$id"
    done
    """)
  end

  # Safe to read once the reply has arrived: pi writes the line before it
  # answers, so a delivered response means the capture is on disk.
  defp last_command(capture_path) do
    capture_path
    |> File.read!()
    |> String.split("\n", trim: true)
    |> List.last()
    |> JSON.decode!()
  end

  defp document_ref(document), do: %{"type" => "document", "id" => document.id}

  defp document_with_block(content) do
    document = insert(:document)
    revision = insert(:document_revision, document: document)
    block = insert(:document_block, revision: revision, content: content, position: 0)

    %{document | latest_revision: %{revision | blocks: [block]}}
  end

  defp conversation! do
    insert(:conversation, assistant_actor_id: insert(:actor, kind: :ai).id)
  end

  # A topic already carried by a live process, so `ensure_hot` finds it hot and
  # starts nothing -- which is how a test gets to choose exactly which stand-in
  # answers its prompts.
  defp hot_conversation!(session_opts) do
    conversation = conversation!()
    {:ok, pid} = PiSession.Supervisor.start_session(session_opts)
    session_id = :sys.get_state(pid).id
    on_exit(fn -> PiSession.close(pid) end)

    {:ok, conversation} = Conversations.attach_session(conversation, session_id)
    # Paid up front: these tests are about the prompt, not about the replay.
    # Reloaded afterwards, because claiming writes to the row and not to the
    # struct -- a stale one here would make a later change look like a no-op.
    Conversations.claim_replay(conversation)
    Conversations.get_conversation!(conversation.id)
  end

  defp connect_socket do
    {:ok, socket} = Phoenix.ChannelTest.connect(PiSocket, %{})
    socket
  end

  defp join!(%{id: conversation_id}, params \\ %{}) do
    {:ok, _reply, socket} =
      subscribe_and_join(connect_socket(), "conversation:#{conversation_id}", params)

    socket
  end

  describe "join" do
    test "joins a cold topic without starting anything", %{tmp_dir: _tmp_dir} do
      conversation = conversation!()
      before = PiSession.Supervisor.count()

      socket = join!(conversation)

      # Opening a panel to read should not cost a process.
      assert PiSession.Supervisor.count() == before
      assert socket.assigns.session_id == nil
      assert_push "pending_ui", %{pending_ui: []}, 5_000
    end

    test "refuses a conversation that does not exist" do
      assert {:error, %{reason: "not_found"}} =
               subscribe_and_join(connect_socket(), "conversation:#{UUIDv7.generate()}", %{})
    end

    test "refuses a malformed conversation id" do
      assert {:error, %{reason: "not_found"}} =
               subscribe_and_join(connect_socket(), "conversation:not-a-uuid", %{})
    end

    # A client that arrives after a notification must still see the question.
    test "pushes questions parked before the client connected", %{tmp_dir: tmp_dir} do
      conversation = hot_conversation!(asking_pi(tmp_dir))
      session_id = conversation.pi_session_id

      Task.start(fn -> PiSession.command(session_id, %{"type" => "prompt"}, :infinity) end)
      assert eventually(fn -> match?({:ok, [_one]}, PiSession.pending_ui(session_id)) end)

      join!(conversation)

      assert_push "pending_ui", %{pending_ui: [%{"id" => "ui-1", "method" => "select"}]}, 5_000
    end
  end

  describe "heating" do
    test "the first prompt starts a process for a cold topic" do
      conversation = conversation!()
      socket = join!(conversation)

      refute Conversations.get_conversation!(conversation.id).pi_session_id

      ref = push(socket, "prompt", %{"message" => "hello"})
      assert_reply ref, :ok, _payload, 5_000

      # You cannot talk to a cold topic, so the one being talked to is hot.
      hot = Conversations.get_conversation!(conversation.id)
      assert hot.pi_session_id
      assert PiSession.alive?(hot.pi_session_id)

      on_exit(fn -> PiSession.close(hot.pi_session_id) end)
    end

    test "a second prompt reuses the process the first one started" do
      conversation = conversation!()
      socket = join!(conversation)

      ref = push(socket, "prompt", %{"message" => "first"})
      assert_reply ref, :ok, _payload, 5_000

      session_id = Conversations.get_conversation!(conversation.id).pi_session_id
      on_exit(fn -> PiSession.close(session_id) end)
      count = PiSession.Supervisor.count()

      ref = push(socket, "prompt", %{"message" => "second"})
      assert_reply ref, :ok, _payload, 5_000

      assert Conversations.get_conversation!(conversation.id).pi_session_id == session_id
      assert PiSession.Supervisor.count() == count
    end

    test "a topic with no AI actor says so rather than starting one" do
      conversation = insert(:conversation, assistant_actor_id: nil)
      socket = join!(conversation)

      ref = push(socket, "prompt", %{"message" => "hello"})
      assert_reply ref, :error, %{reason: "assistant_actor_required"}, 5_000
    end

    test "a raw command does not start a process", %{tmp_dir: _tmp_dir} do
      conversation = conversation!()
      socket = join!(conversation)
      before = PiSession.Supervisor.count()

      # An escape hatch onto a running agent; `get_state` is no reason to spend
      # a session slot.
      ref = push(socket, "command", %{"type" => "get_state"})
      assert_reply ref, :error, %{reason: "not_running"}, 5_000

      assert PiSession.Supervisor.count() == before
    end
  end

  describe "commands" do
    test "replies to a raw command on a hot topic", %{tmp_dir: tmp_dir} do
      socket = join!(hot_conversation!(echo_pi(tmp_dir)))

      ref = push(socket, "command", %{"type" => "get_state"})
      assert_reply ref, :ok, %{"data" => %{"ok" => true}}, 5_000
    end

    test "replies to a prompt", %{tmp_dir: tmp_dir} do
      socket = join!(hot_conversation!(echo_pi(tmp_dir)))

      ref = push(socket, "prompt", %{"message" => "hello"})
      assert_reply ref, :ok, %{"success" => true}, 5_000
    end

    test "rejects an unknown event", %{tmp_dir: tmp_dir} do
      socket = join!(hot_conversation!(echo_pi(tmp_dir)))

      ref = push(socket, "nonsense", %{})
      assert_reply ref, :error, %{reason: "unknown_event"}, 5_000
    end
  end

  describe "prompt references" do
    test "expands a document ref ahead of the message", %{tmp_dir: tmp_dir} do
      capture = Path.join(tmp_dir, "sent.jsonl")
      socket = join!(hot_conversation!(capturing_pi(tmp_dir, capture)))
      document = document_with_block("The quarterly plan")

      expect(DocumentsMock, :get_document!, fn _id -> document end)

      ref =
        push(socket, "prompt", %{"message" => "summarise it", "refs" => [document_ref(document)]})

      assert_reply ref, :ok, _payload, 5_000

      assert %{"message" => message} = last_command(capture)
      assert message =~ ~s(<document id="#{document.id}")
      assert message =~ "The quarterly plan"
      assert String.ends_with?(message, "\n\nsummarise it")
    end

    test "sends an attachment's bytes as an image alongside the text", %{tmp_dir: tmp_dir} do
      capture = Path.join(tmp_dir, "sent.jsonl")
      socket = join!(hot_conversation!(capturing_pi(tmp_dir, capture)))
      attachment = insert(:attachment)
      image = %{"type" => "image", "mimeType" => "image/png", "data" => "QUJD"}

      expect(AttachmentsMock, :get_attachment!, fn _id -> attachment end)
      expect(AttachmentsMock, :image_content, fn _attachment -> {:ok, image} end)
      expect(AttachmentsMock, :touch_attachments, fn _ids -> :ok end)

      ref =
        push(socket, "prompt", %{
          "message" => "what is this?",
          "refs" => [%{"type" => "attachment", "id" => attachment.id}]
        })

      assert_reply ref, :ok, _payload, 5_000

      assert %{"message" => message, "images" => [^image]} = last_command(capture)
      assert message =~ ~s(<attachment id="#{attachment.id}")
    end

    test "omits images entirely when there are none", %{tmp_dir: tmp_dir} do
      capture = Path.join(tmp_dir, "sent.jsonl")
      socket = join!(hot_conversation!(capturing_pi(tmp_dir, capture)))

      ref = push(socket, "prompt", %{"message" => "hello"})
      assert_reply ref, :ok, _payload, 5_000

      refute Map.has_key?(last_command(capture), "images")
    end

    # A prompt that quietly lost its reference is worse than one that failed:
    # the agent would answer with confidence about something it never saw.
    test "refuses the prompt and names everything that is gone", %{tmp_dir: tmp_dir} do
      socket = join!(hot_conversation!(echo_pi(tmp_dir)))

      expect(DocumentsMock, :get_document!, 2, fn _id ->
        raise Ecto.NoResultsError, queryable: RintoPMO.Documents.Document
      end)

      ref =
        push(socket, "prompt", %{
          "message" => "hi",
          "refs" => [
            %{"type" => "document", "id" => UUIDv7.generate()},
            %{"type" => "document", "id" => UUIDv7.generate()}
          ]
        })

      # Every one at once: being asked per broken reference is an
      # interrogation, not a choice.
      assert_reply ref, :error, %{reason: "ref_not_found", details: %{"refs" => refs}}, 5_000
      assert length(refs) == 2
    end

    test "sends the rest once a human has chosen to skip", %{tmp_dir: tmp_dir} do
      capture = Path.join(tmp_dir, "sent.jsonl")
      socket = join!(hot_conversation!(capturing_pi(tmp_dir, capture)))
      gone = UUIDv7.generate()

      expect(DocumentsMock, :get_document!, fn _id ->
        raise Ecto.NoResultsError, queryable: RintoPMO.Documents.Document
      end)

      ref =
        push(socket, "prompt", %{
          "message" => "hi",
          "refs" => [%{"type" => "document", "id" => gone}],
          "on_missing_refs" => "skip"
        })

      assert_reply ref, :ok, _payload, 5_000

      assert %{"message" => message} = last_command(capture)
      assert message =~ ~s(status="unavailable")
    end

    test "refuses a ref it does not understand", %{tmp_dir: tmp_dir} do
      socket = join!(hot_conversation!(echo_pi(tmp_dir)))

      ref = push(socket, "prompt", %{"message" => "hi", "refs" => [%{"type" => "wormhole"}]})
      assert_reply ref, :error, %{reason: "invalid_ref"}, 5_000
    end
  end

  describe "recording and replay" do
    test "records the raw message and its refs, not the expanded prelude", %{tmp_dir: tmp_dir} do
      conversation = hot_conversation!(echo_pi(tmp_dir))
      socket = join!(conversation)
      document = document_with_block("The quarterly plan")
      actor = insert(:actor)

      expect(DocumentsMock, :get_document!, fn _id -> document end)

      ref =
        push(socket, "prompt", %{
          "message" => "summarise it",
          "actor_id" => actor.id,
          "refs" => [document_ref(document)]
        })

      assert_reply ref, :ok, _payload, 5_000

      assert [message] = Conversations.list_messages(conversation, %{})
      assert message.role == :user
      assert message.actor_id == actor.id
      # Replay re-expands against the document as it stands then, so storing
      # the prelude would feed back a stale snapshot.
      assert message.content == "summarise it"
      refute message.content =~ "<document"
      assert [stored_ref] = message.refs
      assert stored_ref.ref_id == document.id
    end

    test "a prompt naming no actor is not recorded", %{tmp_dir: tmp_dir} do
      conversation = hot_conversation!(echo_pi(tmp_dir))
      socket = join!(conversation)

      ref = push(socket, "prompt", %{"message" => "hello"})
      assert_reply ref, :ok, _payload, 5_000

      assert Conversations.list_messages(conversation, %{}) == []
    end

    test "the first prompt after a revive carries the history back", %{tmp_dir: tmp_dir} do
      conversation = conversation!()
      actor = insert(:actor)

      {:ok, _earlier} =
        Conversations.append_message(conversation, %{
          actor_id: actor.id,
          role: :user,
          content: "earlier turn"
        })

      capture = Path.join(tmp_dir, "sent.jsonl")
      {:ok, pid} = PiSession.Supervisor.start_session(capturing_pi(tmp_dir, capture))
      on_exit(fn -> PiSession.close(pid) end)

      # Exactly the state a revive leaves behind: a live but empty process, and
      # a debt of the recent turns owed to it.
      {:ok, conversation} = Conversations.attach_session(conversation, :sys.get_state(pid).id)
      assert conversation.replay_pending

      socket = join!(conversation)
      ref = push(socket, "prompt", %{"message" => "carry on"})
      assert_reply ref, :ok, _payload, 5_000

      assert %{"message" => message} = last_command(capture)
      assert message =~ ~s(<conversation id="#{conversation.id}")
      assert message =~ "earlier turn"
      assert String.ends_with?(message, "\n\ncarry on")

      # Paid once. The next prompt owes nothing.
      refute Conversations.get_conversation!(conversation.id).replay_pending
    end
  end

  describe "suspension" do
    test "pushes a question and answering releases the command", %{tmp_dir: tmp_dir} do
      socket = join!(hot_conversation!(asking_pi(tmp_dir)))

      ref = push(socket, "prompt", %{"message" => "pick one"})

      assert_push "ui_request", %{"id" => "ui-1", "method" => "select"}, 5_000

      answer = push(socket, "answer", %{"ui_id" => "ui-1", "value" => "B"})
      assert_reply answer, :ok, _payload, 5_000

      assert_reply ref, :ok, %{"data" => %{"picked" => "B"}}, 5_000
      assert_push "ui_resolved", %{ui_id: "ui-1"}, 5_000
    end

    test "answering a cold topic says the process is gone" do
      socket = join!(conversation!())

      ref = push(socket, "answer", %{"ui_id" => "ui-1", "cancelled" => true})
      assert_reply ref, :error, %{reason: "not_running"}, 5_000
    end

    test "a cold topic has no parked questions" do
      socket = join!(conversation!())

      ref = push(socket, "pending_ui", %{})
      assert_reply ref, :ok, %{pending_ui: []}, 5_000
    end
  end

  describe "the channel outlives the process" do
    test "an exit is pushed and the next prompt starts a new process", %{tmp_dir: tmp_dir} do
      conversation = hot_conversation!(fake_pi(tmp_dir, "read -r line\nexit 4\n"))
      socket = join!(conversation)
      first_session = conversation.pi_session_id

      ref = push(socket, "prompt", %{"message" => "goodbye"})
      assert_reply ref, :error, _payload, 5_000
      assert_push "exit", %{status: _status}, 5_000

      # The process is gone, the topic is not. Addressing this channel by
      # conversation is what lets the client stay put.
      ref = push(socket, "prompt", %{"message" => "hello again"})
      assert_reply ref, :ok, _payload, 5_000

      second_session = Conversations.get_conversation!(conversation.id).pi_session_id
      on_exit(fn -> PiSession.close(second_session) end)

      assert second_session != first_session
      assert PiSession.alive?(second_session)
    end
  end

  describe "close" do
    test "cools the topic and keeps the channel", %{tmp_dir: tmp_dir} do
      conversation = hot_conversation!(echo_pi(tmp_dir))
      socket = join!(conversation)
      session_id = conversation.pi_session_id

      ref = push(socket, "close", %{})
      assert_reply ref, :ok, %{closed: true}, 5_000

      refute PiSession.alive?(session_id)
      refute Conversations.get_conversation!(conversation.id).pi_session_id

      # Still joined, and prompting heats it again.
      ref = push(socket, "pending_ui", %{})
      assert_reply ref, :ok, %{pending_ui: []}, 5_000
    end
  end

  describe "naming" do
    test "pushes the topic to every client when it is named" do
      conversation = insert(:conversation, title: nil, title_source: nil)
      _one = join!(conversation)
      _two = join!(conversation)
      assert_push "pending_ui", %{pending_ui: []}, 5_000

      insert(:message, conversation: conversation, role: :user, content: "上线流程有没有遗漏")

      stub(TitleGeneratorMock, :generate, fn _input, _opts -> {:ok, "上线流程遗漏检查"} end)
      # Hammox hands expectations to the process that set them, and naming runs
      # here rather than in a worker, so the two joined channels are only
      # receiving what the write broadcasts.
      assert {:ok, _named, :model} = Titles.name(conversation.id)

      # Once per joined client, not once per prompt: a title arriving has to
      # reach the tab that did not ask for it.
      assert_push "conversation_updated", %{data: first}, 5_000
      assert_push "conversation_updated", %{data: second}, 5_000

      assert first.title == "上线流程遗漏检查"
      assert first.title_source == :auto
      assert first.id == conversation.id
      assert second.title == "上线流程遗漏检查"
    end
  end

  defp eventually(condition, attempts \\ 100) do
    cond do
      condition.() -> true
      attempts > 0 -> Process.sleep(20) && eventually(condition, attempts - 1)
      true -> false
    end
  end
end
