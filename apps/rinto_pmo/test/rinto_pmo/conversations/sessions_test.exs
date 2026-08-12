defmodule RintoPMO.Conversations.SessionsTest do
  # Not async: the ceiling is application config, and the pi session registry is
  # global, so these tests own both for their duration.
  use RintoPMO.DataCase, async: false

  alias RintoPMO.Actors
  alias RintoPMO.ActorsMock
  alias RintoPMO.Agent.PiSession
  alias RintoPMO.Conversations
  alias RintoPMO.Conversations.Recorder
  alias RintoPMO.Conversations.Sessions
  alias RintoPMO.ConversationsMock

  @moduletag :capture_log
  @moduletag :tmp_dir

  @fake_pi Path.expand("../../support/fake_pi.sh", __DIR__)

  setup %{tmp_dir: tmp_dir} do
    previous = Application.get_env(:rinto_pmo, RintoPMO.Conversations)

    on_exit(fn ->
      Application.put_env(:rinto_pmo, RintoPMO.Conversations, previous)
      PiSession.Supervisor.close_all()
    end)

    # These tests drive the real contexts rather than the mocks: the point is
    # what happens to the rows when a process is evicted, and heating now reads
    # the assistant actor to learn which model to run.
    stub_with(ConversationsMock, Conversations)
    stub_with(ActorsMock, Actors)

    %{tmp_dir: tmp_dir}
  end

  defp fake_pi(tmp_dir, body) do
    path = Path.join(tmp_dir, "behaviour-#{System.unique_integer([:positive])}.sh")
    File.write!(path, body)
    [executable: @fake_pi, extra_args: [path]]
  end

  defp idle_pi(tmp_dir), do: fake_pi(tmp_dir, "sleep 300\n")

  # Asks a question and never gets an answer -- the case that must never be
  # evicted, since nothing times a question out.
  defp asking_pi(tmp_dir) do
    fake_pi(tmp_dir, """
    printf '%s\\n' '{"type":"extension_ui_request","id":"ui-1","method":"input","title":"Which one?"}'
    sleep 300
    """)
  end

  describe "the assistant a topic runs as" do
    test "heats with the assistant actor's own model and prompt", %{tmp_dir: tmp_dir} do
      capture = Path.join(tmp_dir, "argv")

      actor =
        insert(:actor,
          kind: :ai,
          provider: "anthropic",
          model: "claude-opus-4",
          thinking_level: "high",
          system_prompt: "You review architecture."
        )

      conversation = insert(:conversation, assistant_actor: actor)

      {:ok, _conversation, :revived} =
        Sessions.ensure_hot(conversation,
          session_opts: dumping_pi(tmp_dir, capture)
        )

      assert eventually(fn -> File.exists?(capture) end)
      argv = capture |> File.read!() |> String.split("\n", trim: true)

      assert "--provider" in argv
      assert "anthropic" in argv
      assert "claude-opus-4" in argv
      assert "high" in argv
      assert "You review architecture." in argv
    end

    # A pi process is told which model to be once, at startup, and runs
    # `--no-session`. Writing the row without closing it would leave the topic
    # answering as the old actor with nothing saying so.
    test "switching the assistant cools the topic so the change lands", %{tmp_dir: tmp_dir} do
      conversation = hot_conversation!(tmp_dir)
      session_id = conversation.pi_session_id
      replacement = insert(:actor, kind: :ai, model: "claude-sonnet-4")

      {:ok, switched} = Sessions.switch_assistant(conversation, replacement.id)

      assert switched.assistant_actor_id == replacement.id
      refute switched.pi_session_id
      refute PiSession.alive?(session_id)
    end

    # History lives here rather than in pi, and cooling arms the replay, so the
    # new model is handed the recent turns on the next prompt.
    test "the topic survives the switch, with its replay owed again", %{tmp_dir: tmp_dir} do
      conversation = hot_conversation!(tmp_dir)
      Conversations.claim_replay(conversation)
      refute Conversations.get_conversation!(conversation.id).replay_pending

      replacement = insert(:actor, kind: :ai, model: "claude-sonnet-4")
      {:ok, switched} = Sessions.switch_assistant(conversation, replacement.id)

      {:ok, reheated, :revived} =
        Sessions.ensure_hot(switched, session_opts: idle_pi(tmp_dir))

      assert reheated.replay_pending
    end
  end

  defp eventually(fun, attempts \\ 100)
  defp eventually(_fun, 0), do: false

  defp eventually(fun, attempts) do
    if fun.() do
      true
    else
      Process.sleep(10)
      eventually(fun, attempts - 1)
    end
  end

  defp dumping_pi(tmp_dir, capture) do
    fake_pi(tmp_dir, ~s|printf '%s\\n' "$@" > "#{capture}"\nsleep 300\n|)
  end

  defp set_limit(limit) do
    Application.put_env(:rinto_pmo, RintoPMO.Conversations, max_active_sessions: limit)
  end

  # The AI persona a topic talks to lives on the topic, so heating needs
  # nothing from the caller but a stand-in for pi.
  defp hot_conversation!(tmp_dir, session_opts \\ nil) do
    conversation = insert(:conversation, assistant_actor: build(:actor, kind: :ai))

    {:ok, conversation, :revived} =
      Sessions.ensure_hot(conversation, session_opts: session_opts || idle_pi(tmp_dir))

    conversation
  end

  describe "ensure_hot/2" do
    test "revives a cold topic and records the session on it", %{tmp_dir: tmp_dir} do
      set_limit(4)

      conversation = insert(:conversation, assistant_actor: build(:actor, kind: :ai))

      refute Sessions.hot?(conversation)

      assert {:ok, hot, :revived} =
               Sessions.ensure_hot(conversation, session_opts: idle_pi(tmp_dir))

      assert hot.pi_session_id != nil
      assert Sessions.hot?(hot)
      assert PiSession.alive?(hot.pi_session_id)
      assert Recorder.recording?(hot.id)
      # The new process is empty, so the next prompt owes it the recent turns.
      assert hot.replay_pending

      assert Conversations.get_conversation!(conversation.id).pi_session_id ==
               hot.pi_session_id
    end

    test "leaves an already hot topic alone", %{tmp_dir: tmp_dir} do
      set_limit(4)

      hot = hot_conversation!(tmp_dir)

      assert {:ok, same, :hot} = Sessions.ensure_hot(hot)

      assert same.pi_session_id == hot.pi_session_id
    end

    test "a topic whose process died reads as cold", %{tmp_dir: tmp_dir} do
      set_limit(4)

      hot = hot_conversation!(tmp_dir)
      :ok = PiSession.close(hot.pi_session_id)

      # The column still names the session; only the process is gone. Hotness
      # is the check of that claim, not the claim itself.
      assert hot.pi_session_id != nil
      refute Sessions.hot?(hot)
    end
  end

  describe "the session ceiling" do
    test "reports room below the limit", %{tmp_dir: tmp_dir} do
      set_limit(4)
      _hot = hot_conversation!(tmp_dir)

      assert {:ok, :room} = Sessions.make_room()
    end

    test "evicts the idlest session at the limit", %{tmp_dir: tmp_dir} do
      set_limit(2)

      first = hot_conversation!(tmp_dir)
      # Touched after the first, so the first is the idler of the two.
      second = hot_conversation!(tmp_dir)
      {:ok, _info} = PiSession.info(second.pi_session_id)

      assert {:ok, :evicted, evicted} = Sessions.make_room()
      assert evicted.id == first.pi_session_id

      refute PiSession.alive?(first.pi_session_id)
      assert PiSession.alive?(second.pi_session_id)
    end

    test "eviction only cools: the topic and its messages survive", %{tmp_dir: tmp_dir} do
      set_limit(1)

      conversation = hot_conversation!(tmp_dir)
      actor = insert(:actor)

      {:ok, _message} =
        Conversations.append_message(conversation, %{
          actor_id: actor.id,
          role: :user,
          content: "Said before eviction"
        })

      assert {:ok, :evicted, _info} = Sessions.make_room()

      cooled = Conversations.get_conversation!(conversation.id)
      assert cooled.pi_session_id == nil
      refute Sessions.hot?(cooled)
      refute Recorder.recording?(cooled.id)

      assert Enum.map(Conversations.list_messages(cooled, %{}), & &1.content) ==
               ["Said before eviction"]
    end

    test "never evicts a session waiting on a human", %{tmp_dir: tmp_dir} do
      set_limit(1)

      asking = hot_conversation!(tmp_dir, asking_pi(tmp_dir))

      # The question has to have arrived before the ceiling is tested.
      wait_for_pending_ui(asking.pi_session_id)

      assert {:error, :session_limit_reached} = Sessions.make_room()
      assert PiSession.alive?(asking.pi_session_id)

      assert Conversations.get_conversation!(asking.id).pi_session_id ==
               asking.pi_session_id
    end

    test "evicts an idle session in preference to one holding a question", %{tmp_dir: tmp_dir} do
      set_limit(2)

      asking = hot_conversation!(tmp_dir, asking_pi(tmp_dir))
      wait_for_pending_ui(asking.pi_session_id)

      idle = hot_conversation!(tmp_dir)

      assert {:ok, :evicted, evicted} = Sessions.make_room()
      assert evicted.id == idle.pi_session_id
      assert PiSession.alive?(asking.pi_session_id)
    end

    test "refuses to revive when every session is waiting on a human", %{tmp_dir: tmp_dir} do
      set_limit(1)

      asking = hot_conversation!(tmp_dir, asking_pi(tmp_dir))
      wait_for_pending_ui(asking.pi_session_id)

      conversation = insert(:conversation, assistant_actor: build(:actor, kind: :ai))

      assert {:error, :session_limit_reached} =
               Sessions.ensure_hot(conversation, session_opts: idle_pi(tmp_dir))

      assert Conversations.get_conversation!(conversation.id).pi_session_id == nil
    end
  end

  describe "cool/1" do
    test "closes the process and keeps the record", %{tmp_dir: tmp_dir} do
      set_limit(4)

      hot = hot_conversation!(tmp_dir)
      session_id = hot.pi_session_id

      assert {:ok, cold} = Sessions.cool(hot)

      assert cold.pi_session_id == nil
      refute PiSession.alive?(session_id)
      refute Recorder.recording?(cold.id)
      assert Conversations.get_conversation!(hot.id).id == hot.id
    end

    test "refuses to heat a topic with no AI persona to answer as" do
      conversation = insert(:conversation, assistant_actor: nil)

      assert {:error, :assistant_actor_required} = Sessions.ensure_hot(conversation)
    end

    test "is a no-op on an already cold topic" do
      conversation = insert(:conversation)

      assert {:ok, still_cold} = Sessions.cool(conversation)
      assert still_cold.pi_session_id == nil
    end
  end

  defp wait_for_pending_ui(session_id, attempts \\ 100) do
    case PiSession.pending_ui(session_id) do
      {:ok, [_request | _rest]} ->
        :ok

      _not_yet when attempts > 0 ->
        Process.sleep(20)
        wait_for_pending_ui(session_id, attempts - 1)

      _exhausted ->
        flunk("pi never asked its question")
    end
  end
end
