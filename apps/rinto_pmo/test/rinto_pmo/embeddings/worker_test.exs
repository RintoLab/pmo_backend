defmodule RintoPMO.Embeddings.WorkerTest do
  use RintoPMO.DataCase, async: true

  import Hammox

  alias RintoPMO.AIMock
  alias RintoPMO.Annotations.Annotation
  alias RintoPMO.Annotations.AnnotationReply
  alias RintoPMO.Attachments.Attachment
  alias RintoPMO.Conversations.Conversation
  alias RintoPMO.Documents.DocumentBlock
  alias RintoPMO.Embeddings.Worker
  alias RintoPMO.Projects.Project
  alias RintoPMO.Tasks.Task

  setup :verify_on_exit!

  defp vector, do: List.duplicate(0.1, 1024)

  # Answers one vector per text, so a mismatch between what was asked for and
  # what came back would fail rather than pass quietly.
  defp expect_embedding(fun) do
    expect(AIMock, :embed_documents, fn texts ->
      fun.(texts)
      {:ok, Enum.map(texts, fn _text -> vector() end)}
    end)
  end

  defp run, do: Worker.perform(%Oban.Job{args: %{}})

  # A task cannot exist without a project, so inserting one leaves two sources
  # outstanding. Settling the rest is how a test says which source it is about.
  defp settle(schema) do
    schema
    |> where([row], is_nil(row.embedding))
    |> Repo.update_all(set: [embedding: Pgvector.new(vector())])
  end

  defp settle_all_but(schema) do
    for {other, _fields} <- [
          {DocumentBlock, nil},
          {Task, nil},
          {Project, nil},
          {Annotation, nil},
          {AnnotationReply, nil},
          {Conversation, nil},
          {Attachment, nil}
        ],
        other != schema do
      settle(other)
    end
  end

  describe "what gets picked up" do
    test "a row with no vector is embedded" do
      task = insert(:task, title: "接入 r-nacos", description: "先确认 systemd unit")
      settle_all_but(Task)

      expect_embedding(fn texts ->
        assert texts == ["接入 r-nacos\n\n先确认 systemd unit"]
      end)

      assert :ok = run()
      assert Repo.get!(Task, task.id).embedding
    end

    test "a row that already has one is left alone" do
      insert(:task)
      settle(Task)
      settle_all_but(Task)

      # No `expect` for AIMock: calling it at all would fail the test.
      assert :ok = run()
    end

    # The rule the pass would otherwise spin on forever: an unnamed topic has
    # nothing to embed, so it must not keep presenting itself as outstanding.
    test "a row with nothing to embed is not picked up" do
      insert(:conversation, title: nil)

      assert :ok = run()
      assert Repo.one!(from row in Conversation, select: count()) == 1
    end

    test "blanks are dropped rather than joined into the text" do
      insert(:task, title: "只有标题", description: nil)
      settle_all_but(Task)

      expect_embedding(fn texts -> assert texts == ["只有标题"] end)

      assert :ok = run()
    end
  end

  describe "when the service is unavailable" do
    # The null column already records what is outstanding, so a failure needs
    # to leave the rows exactly as they are and nothing else.
    test "the rows are left for the next pass" do
      task = insert(:task)
      settle_all_but(Task)

      expect(AIMock, :embed_documents, fn _texts -> {:error, {:transport, :econnrefused}} end)

      assert :ok = run()
      refute Repo.get!(Task, task.id).embedding
    end

    test "a later pass picks them up" do
      task = insert(:task)
      settle_all_but(Task)

      expect(AIMock, :embed_documents, fn _texts -> {:error, :not_configured} end)
      assert :ok = run()

      expect_embedding(fn _texts -> :ok end)
      assert :ok = run()

      assert Repo.get!(Task, task.id).embedding
    end
  end

  describe "pacing" do
    test "a pass queues the next one" do
      assert :ok = run()

      assert [job] = Repo.all(Oban.Job)
      assert job.worker == "RintoPMO.Embeddings.Worker"
    end

    # A full batch means there is more waiting than one pass could take, and
    # draining that fifteen seconds at a time would be needlessly slow.
    test "a full batch comes straight back rather than waiting out the interval" do
      batch = Application.fetch_env!(:rinto_pmo, Worker)[:batch_size]
      project = insert(:project)
      for _ <- 1..batch, do: insert(:task, project: project)
      settle_all_but(Task)

      expect_embedding(fn texts -> assert length(texts) == batch end)

      assert :ok = run()

      assert [job] = Repo.all(Oban.Job)
      assert DateTime.diff(job.scheduled_at, DateTime.utc_now()) < 5
    end

    test "an idle pass waits" do
      interval = Application.fetch_env!(:rinto_pmo, Worker)[:interval_seconds]

      assert :ok = run()

      assert [job] = Repo.all(Oban.Job)
      assert DateTime.diff(job.scheduled_at, DateTime.utc_now()) > interval - 5
    end
  end

  describe "across sources" do
    test "every kind of thing with text is covered in one pass" do
      insert(:task, title: "任务")
      insert(:conversation, title: "话题")

      insert(:document_block,
        revision: insert(:document_revision),
        content: "## 一节\n\n内容"
      )

      # One call per source that had rows, not one per row: block, task, the
      # project the task brought with it, and the conversation.
      expect(AIMock, :embed_documents, 4, fn texts ->
        {:ok, Enum.map(texts, fn _ -> vector() end)}
      end)

      assert :ok = run()

      assert Repo.one!(from row in DocumentBlock, select: count(row.embedding)) == 1
      assert Repo.one!(from row in Task, select: count(row.embedding)) == 1
      assert Repo.one!(from row in Conversation, select: count(row.embedding)) == 1
    end
  end
end
