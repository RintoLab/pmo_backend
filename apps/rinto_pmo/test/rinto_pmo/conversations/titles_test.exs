defmodule RintoPMO.Conversations.TitlesTest do
  use RintoPMO.DataCase, async: true
  use Oban.Testing, repo: RintoPMO.Repo

  alias RintoPMO.Actors
  alias RintoPMO.ActorsMock
  alias RintoPMO.Agent.TitleGeneratorMock
  alias RintoPMO.Conversations
  alias RintoPMO.Conversations.Conversation
  alias RintoPMO.Conversations.Notifier
  alias RintoPMO.Conversations.Titles
  alias RintoPMO.Conversations.TitleWorker
  alias RintoPMO.DocumentsMock
  alias RintoPMO.Settings

  # A topic carries an assistant by default now, and naming falls back to it when
  # no naming actor is configured -- so the real context answers unless a test
  # says otherwise.
  setup do
    stub_with(ActorsMock, Actors)
    :ok
  end

  describe "eligibility" do
    test "an empty topic is created unnamed and stays that way" do
      assert {:ok, conversation} = Conversations.create_conversation(%{})

      assert conversation.title == nil
      assert conversation.title_source == nil
      assert Titles.eligible?(conversation)

      assert Titles.name(conversation.id) == :ignore
      assert reload(conversation).title == nil
    end

    test "a topic created with a title belongs to whoever named it" do
      assert {:ok, conversation} = Conversations.create_conversation(%{title: "Tighten §3"})

      assert conversation.title_source == :manual
      refute Titles.eligible?(conversation)
    end

    test "renaming a topic makes the name a person's" do
      conversation = insert(:conversation, title: "上线流程遗漏检查", title_source: :auto)

      assert {:ok, renamed} =
               Conversations.update_conversation(conversation, %{"title" => "上线复盘"})

      assert renamed.title_source == :manual
      assert renamed.title_generated_at == nil
    end

    test "a title of nothing but spaces is no title" do
      conversation = insert(:conversation, title: "Old", title_source: :manual)

      assert {:ok, updated} = Conversations.update_conversation(conversation, %{"title" => "   "})
      assert updated.title == nil
      assert updated.title_source == :manual
    end

    test "changing something other than the title leaves the name alone" do
      conversation = insert(:conversation, title: nil, title_source: nil)
      actor = insert(:actor, kind: :ai)

      assert {:ok, updated} =
               Conversations.update_conversation(conversation, %{
                 "assistant_actor_id" => actor.id
               })

      assert updated.title_source == nil
      assert Titles.eligible?(updated)
    end

    test "a topic a person cleared is never named again" do
      conversation = insert(:conversation, title: "Old", title_source: :manual)

      assert {:ok, cleared} = Conversations.update_conversation(conversation, %{"title" => nil})
      assert cleared.title == nil
      assert cleared.title_source == :manual

      refute Titles.eligible?(cleared)
      assert Titles.enqueue(cleared.id) == :ignore
      assert Titles.name(cleared.id) == :ignore
    end
  end

  describe "queueing" do
    test "the first user message queues naming once" do
      conversation = unnamed()

      append(conversation, "帮我看看这个文档的上线流程有没有遗漏")

      assert_enqueued(worker: TitleWorker, args: %{conversation_id: conversation.id})
      assert length(all_enqueued()) == 1
    end

    test "later messages do not queue naming again" do
      conversation = unnamed()

      append(conversation, "first")
      append(conversation, "second")
      append(conversation, "third")

      assert length(all_enqueued()) == 1
    end

    test "an assistant turn never queues naming" do
      conversation = unnamed()
      assistant = insert(:actor, kind: :ai, provider: "google", model: "gemini")

      assert {:ok, _message} =
               Conversations.append_message(conversation, %{
                 actor_id: assistant.id,
                 role: :assistant,
                 content: "Sure."
               })

      assert all_enqueued() == []
    end

    test "a topic that already has a title queues nothing" do
      conversation = insert(:conversation, title: "Named", title_source: :manual)

      append(conversation, "hello")

      assert all_enqueued() == []
    end

    test "a job for a topic nobody has spoken in names nothing" do
      conversation = unnamed()

      assert :ok = perform_job(TitleWorker, %{conversation_id: conversation.id})
      assert reload(conversation).title == nil
    end

    test "a job for a conversation that no longer exists is not an error" do
      assert :ok = perform_job(TitleWorker, %{conversation_id: UUIDv7.generate()})
    end

    test "the message still lands when naming is switched off" do
      previous = Application.get_env(:rinto_pmo, Titles, [])
      Application.put_env(:rinto_pmo, Titles, Keyword.put(previous, :enabled, false))
      on_exit(fn -> Application.put_env(:rinto_pmo, Titles, previous) end)

      conversation = unnamed()

      assert %{content: "hello"} = append(conversation, "hello")
      assert all_enqueued() == []
      assert reload(conversation).title == nil
    end
  end

  describe "naming" do
    test "writes the model's title, tidied" do
      conversation = unnamed()
      append(conversation, "为什么选 WebSocket 而不是 SSE？")

      expect(TitleGeneratorMock, :generate, fn _input, _opts ->
        {:ok, ~s(## 标题："WebSocket 与 SSE 选型"\n\n希望有帮助。)}
      end)

      assert {:ok, named, :model} = Titles.name(conversation.id)
      assert named.title == "WebSocket 与 SSE 选型"
      assert named.title_source == :auto
      assert named.title_generated_at
    end

    test "runs from the worker, and the worker is what the message queued" do
      conversation = unnamed()
      append(conversation, "数据库迁移失败以后应该怎么回滚")

      expect(TitleGeneratorMock, :generate, fn _input, _opts -> {:ok, "数据库迁移回滚方案"} end)

      assert :ok = perform_job(TitleWorker, %{conversation_id: conversation.id})
      assert reload(conversation).title == "数据库迁移回滚方案"
    end

    test "falls back to the message when the model fails" do
      conversation = unnamed()
      append(conversation, "数据库迁移失败以后应该怎么回滚。还有别的问题。")

      expect(TitleGeneratorMock, :generate, fn _input, _opts -> {:error, :timeout} end)

      assert {:ok, named, :fallback} = Titles.name(conversation.id)
      assert named.title == "数据库迁移失败以后应该怎么回滚"
      assert named.title_source == :auto
    end

    test "falls back when the model raises" do
      conversation = unnamed()
      append(conversation, "Why WebSocket over SSE?")

      expect(TitleGeneratorMock, :generate, fn _input, _opts -> raise "provider on fire" end)

      assert {:ok, named, :fallback} = Titles.name(conversation.id)
      assert named.title == "Why WebSocket over SSE?"
    end

    test "falls back when the model answers with nothing usable" do
      conversation = unnamed()
      append(conversation, "Rollback plan for the failed migration")

      expect(TitleGeneratorMock, :generate, fn _input, _opts -> {:ok, "  \n ## \n"} end)

      assert {:ok, named, :fallback} = Titles.name(conversation.id)
      assert named.title == "Rollback plan for the failed migration"
    end

    test "names from the first user message, not the latest" do
      conversation = unnamed()
      append(conversation, "上线流程有没有遗漏")
      append(conversation, "顺便看看回滚脚本")

      expect(TitleGeneratorMock, :generate, fn input, _opts ->
        assert input.first_user_message == "上线流程有没有遗漏"
        assert input.locale == "zh-CN"
        {:ok, "上线流程遗漏检查"}
      end)

      assert {:ok, named, :model} = Titles.name(conversation.id)
      assert named.title == "上线流程遗漏检查"
    end

    test "asks whichever actor was put in the naming role" do
      namer = insert(:actor, kind: :ai, provider: "google", model: "flash", thinking_level: "off")
      assistant = insert(:actor, kind: :ai, provider: "anthropic", model: "opus")

      assert {:ok, _settings} = Settings.put_actor("title_actor", namer.id)

      conversation = unnamed(assistant_actor: assistant)
      append(conversation, "上线流程有没有遗漏")

      expect(TitleGeneratorMock, :generate, fn _input, opts ->
        assert opts[:provider] == "google"
        assert opts[:model] == "flash"
        assert opts[:thinking] == "off"
        {:ok, "上线流程遗漏检查"}
      end)

      assert {:ok, _named, :model} = Titles.name(conversation.id)
    end

    test "falls back to the topic's assistant when the naming actor is turned off" do
      namer =
        insert(:actor, kind: :ai, provider: "google", model: "flash", thinking_level: "off")

      assistant = insert(:actor, kind: :ai, provider: "anthropic", model: "opus")

      assert {:ok, _settings} = Settings.put_actor("title_actor", namer.id)
      assert {:ok, _disabled} = Actors.update_actor(namer, %{"enabled" => false})

      conversation = unnamed(assistant_actor: assistant)
      append(conversation, "上线流程有没有遗漏")

      expect(ActorsMock, :get_actor!, fn _id -> assistant end)

      expect(TitleGeneratorMock, :generate, fn _input, opts ->
        assert opts[:model] == "opus"
        {:ok, "上线流程遗漏检查"}
      end)

      assert {:ok, _named, :model} = Titles.name(conversation.id)
    end

    test "sends the topic's assistant provider and model as the default" do
      actor = insert(:actor, kind: :ai, provider: "google", model: "gemini-flash")
      conversation = unnamed(assistant_actor: actor)
      append(conversation, "hello")

      expect(ActorsMock, :get_actor!, fn id ->
        assert id == actor.id
        actor
      end)

      expect(TitleGeneratorMock, :generate, fn _input, opts ->
        assert opts[:provider] == "google"
        assert opts[:model] == "gemini-flash"
        {:ok, "A greeting"}
      end)

      assert {:ok, _named, :model} = Titles.name(conversation.id)
    end
  end

  describe "references" do
    test "describes a referenced document by title, never by contents" do
      document = document_titled("项目上线方案")
      conversation = unnamed()
      append(conversation, "帮我看看这个", [%{"type" => "document", "id" => document.id}])

      expect(DocumentsMock, :get_document!, fn _id -> document end)

      expect(TitleGeneratorMock, :generate, fn input, _opts ->
        assert [%{type: "document", title: "项目上线方案"}] = input.references
        refute input.first_user_message =~ "Body text"
        {:ok, "项目上线方案检查"}
      end)

      assert {:ok, named, :model} = Titles.name(conversation.id)
      assert named.title == "项目上线方案检查"
    end

    test "a gesture of a message falls back to what it pointed at" do
      document = document_titled("项目上线方案")
      conversation = unnamed()
      append(conversation, "帮我看看这个", [%{"type" => "document", "id" => document.id}])

      # Once for the model's input, once for the fallback.
      stub(DocumentsMock, :get_document!, fn _id -> document end)
      expect(TitleGeneratorMock, :generate, fn _input, _opts -> {:error, :pi_not_found} end)

      assert {:ok, named, :fallback} = Titles.name(conversation.id)
      assert named.title == "项目上线方案"
    end

    test "a reference whose target is gone still names the topic" do
      conversation = unnamed()
      append(conversation, "看看这个", [%{"type" => "document", "id" => UUIDv7.generate()}])

      stub(DocumentsMock, :get_document!, fn _id -> raise Ecto.NoResultsError, queryable: nil end)

      expect(TitleGeneratorMock, :generate, fn input, _opts ->
        assert [%{type: "document"}] = input.references
        {:ok, "文档检查"}
      end)

      assert {:ok, named, :model} = Titles.name(conversation.id)
      assert named.title == "文档检查"
    end
  end

  describe "not overwriting a person" do
    test "a second run changes nothing" do
      conversation = unnamed()
      append(conversation, "上线流程有没有遗漏")

      expect(TitleGeneratorMock, :generate, fn _input, _opts -> {:ok, "上线流程遗漏检查"} end)

      assert {:ok, _named, :model} = Titles.name(conversation.id)
      # The second attempt does not even reach the model: verify_on_exit! would
      # fail on a call that was not expected.
      assert Titles.name(conversation.id) == :ignore
      assert reload(conversation).title == "上线流程遗漏检查"
    end

    test "two jobs racing produce one title" do
      conversation = unnamed()
      append(conversation, "上线流程有没有遗漏")

      assert {:ok, _first} = Titles.apply_title(conversation.id, "第一个标题")
      assert Titles.apply_title(conversation.id, "第二个标题") == :stale

      assert reload(conversation).title == "第一个标题"
    end

    test "a rename during the model call wins" do
      conversation = unnamed()
      append(conversation, "上线流程有没有遗漏")

      expect(TitleGeneratorMock, :generate, fn _input, _opts ->
        {:ok, _renamed} =
          Conversations.update_conversation(reload(conversation), %{"title" => "我自己取的"})

        {:ok, "模型取的"}
      end)

      assert Titles.name(conversation.id) == :stale

      named = reload(conversation)
      assert named.title == "我自己取的"
      assert named.title_source == :manual
    end

    test "naming does not disturb the list's ordering" do
      conversation = unnamed()
      append(conversation, "上线流程有没有遗漏")
      before = reload(conversation).updated_at

      expect(TitleGeneratorMock, :generate, fn _input, _opts -> {:ok, "上线流程遗漏检查"} end)
      assert {:ok, _named, :model} = Titles.name(conversation.id)

      assert reload(conversation).updated_at == before
    end
  end

  describe "broadcasting" do
    test "announces the named conversation to everyone on the topic" do
      conversation = unnamed()
      append(conversation, "上线流程有没有遗漏")
      :ok = Notifier.subscribe(conversation.id)

      expect(TitleGeneratorMock, :generate, fn _input, _opts -> {:ok, "上线流程遗漏检查"} end)
      assert {:ok, _named, :model} = Titles.name(conversation.id)

      assert_receive {:conversation_updated, %Conversation{} = broadcast}
      assert broadcast.id == conversation.id
      assert broadcast.title == "上线流程遗漏检查"
      assert broadcast.title_source == :auto
    end

    test "says nothing when it did not name anything" do
      conversation = unnamed()
      :ok = Notifier.subscribe(conversation.id)

      assert Titles.name(conversation.id) == :ignore

      refute_receive {:conversation_updated, _conversation}
    end
  end

  describe "sanitise/1" do
    test "keeps a Chinese title inside 24 characters" do
      {:ok, title} = Titles.sanitise(String.duplicate("上线流程遗漏检查", 5))

      assert String.length(title) == 24
    end

    test "keeps an English title inside 60 characters" do
      {:ok, title} = Titles.sanitise(String.duplicate("rollback plan ", 20))

      assert String.length(title) <= 60
    end

    test "strips headings, quote pairs, labels and trailing stops" do
      assert Titles.sanitise(~s(# "Rollback plan".)) == {:ok, "Rollback plan"}
      assert Titles.sanitise("Title: Rollback plan") == {:ok, "Rollback plan"}
      assert Titles.sanitise("标题：「回滚方案」") == {:ok, "回滚方案"}
      assert Titles.sanitise("- 回滚方案。") == {:ok, "回滚方案"}
    end

    test "keeps 《》, which names a document rather than quoting one" do
      assert Titles.sanitise("《项目上线方案》评审") == {:ok, "《项目上线方案》评审"}
    end

    test "takes the first line and drops the model's commentary" do
      assert Titles.sanitise("回滚方案\n\n这个标题概括了讨论内容。") == {:ok, "回滚方案"}
    end

    test "reports nothing usable rather than an empty title" do
      assert Titles.sanitise("   \n ## ") == :error
      assert Titles.sanitise(nil) == :error
    end
  end

  describe "pending/1" do
    test "lists only unnamed topics that have something to be named after" do
      empty = unnamed()
      named = insert(:conversation, title: "Named", title_source: :manual)
      cleared = insert(:conversation, title: nil, title_source: :manual)
      auto = insert(:conversation, title: "Auto", title_source: :auto)

      spoken = unnamed()
      append(spoken, "hello")

      assert Titles.pending() == [spoken.id]

      refute empty.id in Titles.pending()
      refute named.id in Titles.pending()
      refute cleared.id in Titles.pending()
      refute auto.id in Titles.pending()
    end

    test "takes a limit" do
      first = unnamed()
      second = unnamed()
      append(first, "one")
      append(second, "two")

      assert [id] = Titles.pending(1)
      assert id == Enum.min([first.id, second.id])
    end
  end

  defp unnamed(attrs \\ []) do
    insert(:conversation, Keyword.merge([title: nil, title_source: nil], attrs))
  end

  defp append(conversation, content, refs \\ []) do
    {:ok, message} =
      Conversations.append_message(conversation, %{
        actor_id: insert(:actor).id,
        role: :user,
        content: content,
        refs: refs
      })

    message
  end

  defp reload(%Conversation{id: id}), do: Repo.get!(Conversation, id)

  defp document_titled(title) do
    document = insert(:document)
    revision = insert(:document_revision, document: document, title: title)
    block = insert(:document_block, revision: revision, content: "Body text", position: 0)

    %{document | latest_revision: %{revision | blocks: [block]}}
  end
end
