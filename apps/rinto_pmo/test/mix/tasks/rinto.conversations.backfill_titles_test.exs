defmodule Mix.Tasks.Rinto.Conversations.BackfillTitlesTest do
  # Not async: the task writes to `Mix.shell()`, which is global, and runs its
  # naming calls in tasks of its own, which need the shared sandbox.
  use RintoPMO.DataCase, async: false

  alias Mix.Tasks.Rinto.Conversations.BackfillTitles
  alias RintoPMO.Agent.TitleGeneratorMock
  alias RintoPMO.Conversations
  alias RintoPMO.Conversations.Conversation

  setup do
    previous = Mix.shell()
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(previous) end)
    :ok
  end

  test "names the topics that were left unnamed" do
    spoken = unnamed()
    append(spoken, "数据库迁移失败以后应该怎么回滚")

    stub(TitleGeneratorMock, :generate, fn _input, _opts -> {:ok, "数据库迁移回滚方案"} end)

    run(["--concurrency", "1"])

    assert reload(spoken).title == "数据库迁移回滚方案"
    assert reload(spoken).title_source == :auto
    assert_received {:mix_shell, :info, ["1 conversation(s) to name"]}
    assert_received {:mix_shell, :info, [report]}
    assert report =~ "named by model:    1"
  end

  test "leaves empty topics and named topics alone" do
    empty = unnamed()
    named = insert(:conversation, title: "Named", title_source: :manual)
    append(named, "hello")

    run(["--concurrency", "1"])

    assert_received {:mix_shell, :info, ["0 conversation(s) to name"]}
    assert reload(empty).title == nil
    assert reload(named).title == "Named"
  end

  test "does not disturb the order the list is read in" do
    spoken = unnamed()
    append(spoken, "上线流程有没有遗漏")
    before = reload(spoken).updated_at

    stub(TitleGeneratorMock, :generate, fn _input, _opts -> {:ok, "上线流程遗漏检查"} end)

    run(["--concurrency", "1"])

    assert reload(spoken).updated_at == before
  end

  test "counts the ones that fell back to the message" do
    spoken = unnamed()
    append(spoken, "Rollback plan for the failed migration")

    stub(TitleGeneratorMock, :generate, fn _input, _opts -> {:error, :pi_not_found} end)

    run(["--concurrency", "1"])

    assert reload(spoken).title == "Rollback plan for the failed migration"
    assert_received {:mix_shell, :info, [_count]}
    assert_received {:mix_shell, :info, [report]}
    assert report =~ "named by fallback: 1"
  end

  test "reports without writing anything under --dry-run" do
    spoken = unnamed()
    append(spoken, "上线流程有没有遗漏")

    run(["--dry-run"])

    assert_received {:mix_shell, :info, ["1 conversation(s) to name"]}
    refute_received {:mix_shell, :info, [_report]}
    assert reload(spoken).title == nil
  end

  test "running it a second time changes nothing" do
    spoken = unnamed()
    append(spoken, "上线流程有没有遗漏")

    stub(TitleGeneratorMock, :generate, fn _input, _opts -> {:ok, "上线流程遗漏检查"} end)

    run(["--concurrency", "1"])
    named = reload(spoken)

    run(["--concurrency", "1"])

    assert reload(spoken).title == named.title
    assert reload(spoken).title_generated_at == named.title_generated_at
  end

  # `app.start` is already done by the test run, so the task's own call to it is
  # a no-op -- but it still needs Mix to consider the task runnable again.
  defp run(argv) do
    Mix.Task.reenable("rinto.conversations.backfill_titles")
    BackfillTitles.run(argv)
  end

  defp unnamed, do: insert(:conversation, title: nil, title_source: nil)

  defp append(conversation, content) do
    {:ok, message} =
      Conversations.append_message(conversation, %{
        actor_id: insert(:actor).id,
        role: :user,
        content: content
      })

    message
  end

  defp reload(%Conversation{id: id}), do: Repo.get!(Conversation, id)
end
