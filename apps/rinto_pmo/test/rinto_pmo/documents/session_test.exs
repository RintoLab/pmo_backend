defmodule RintoPMO.Documents.SessionTest do
  use RintoPMO.DataCase, async: true

  alias Ecto.Adapters.SQL.Sandbox
  alias RintoPMO.Annotations
  alias RintoPMO.AnnotationsMock
  alias RintoPMO.Documents
  alias RintoPMO.Documents.BlockProposal
  alias RintoPMO.Documents.Session

  @moduletag :capture_log

  setup do
    stub_with(AnnotationsMock, Annotations)
    :ok
  end

  describe "lifecycle" do
    test "opens a session for a document" do
      %{document: document} = document_with_blocks(["One"])

      refute Session.open?(document.id)
      _pid = start_session!(document)
      assert Session.open?(document.id)
    end

    test "a second start returns the session already open" do
      %{document: document} = document_with_blocks(["One"])

      pid = start_session!(document)
      assert {:ok, ^pid} = Session.Supervisor.start_session(document_id: document.id)
    end

    test "calls against a closed session say so" do
      %{document: document} = document_with_blocks(["One"])

      assert {:error, :not_found} = Session.contentions(document.id)
      assert {:error, :not_found} = Session.get_blocks(document.id, UUIDv7.generate())
    end
  end

  describe "proposing through the session" do
    test "serialises proposals and reports contention" do
      %{document: document, blocks: [block | _rest]} = document_with_blocks(["Original"])
      start_session!(document)

      actor = insert(:actor)
      first = insert(:conversation)
      second = insert(:conversation)

      assert {:ok, %{live_proposals: 1}} =
               Session.propose(document.id, block.block_id, first.id, actor.id, "Version A")

      assert {:ok, %{live_proposals: 2}} =
               Session.propose(document.id, block.block_id, second.id, actor.id, "Version B")

      assert {:ok, [%{block_id: contended}]} = Session.contentions(document.id)
      assert contended == block.block_id
    end

    test "each topic reads its own proposal and only the count of others" do
      %{document: document, blocks: [block | _rest]} = document_with_blocks(["Original"])
      start_session!(document)

      actor = insert(:actor)
      mine = insert(:conversation)
      theirs = insert(:conversation)

      {:ok, _} = Session.propose(document.id, block.block_id, mine.id, actor.id, "Mine")
      {:ok, _} = Session.propose(document.id, block.block_id, theirs.id, actor.id, "Theirs")

      assert {:ok, [seen]} = Session.get_blocks(document.id, mine.id)
      assert seen.content == "Mine"
      assert seen.other_proposals == 1
    end
  end

  describe "the process owns nothing" do
    test "proposals survive the session being killed" do
      %{document: document, blocks: [block | _rest]} = document_with_blocks(["Original"])
      pid = start_session!(document)

      actor = insert(:actor)
      conversation = insert(:conversation)

      {:ok, %{proposal: proposal}} =
        Session.propose(document.id, block.block_id, conversation.id, actor.id, "Survives")

      ref = Process.monitor(pid)
      Process.exit(pid, :kill)
      assert_receive {:DOWN, ^ref, :process, ^pid, :killed}
      refute Session.open?(document.id)

      # Nothing was only in the process, so nothing went with it.
      assert Repo.get!(BlockProposal, proposal.id).status == :live

      restarted = start_session!(document)
      assert restarted != pid

      assert {:ok, [seen]} = Session.get_blocks(document.id, conversation.id)
      assert seen.content == "Survives"
      assert seen.proposal_id == proposal.id
    end

    test "a session sees proposals written without one" do
      %{document: document, blocks: [block | _rest]} = document_with_blocks(["Original"])
      conversation = insert(:conversation)

      {:ok, _} =
        Documents.propose_block(document, %{
          block_id: block.block_id,
          conversation_id: conversation.id,
          actor_id: insert(:actor).id,
          content: "Written directly"
        })

      start_session!(document)

      assert {:ok, [seen]} = Session.get_blocks(document.id, conversation.id)
      assert seen.content == "Written directly"
    end
  end

  describe "deciding and committing" do
    test "decides a contention then commits the survivor" do
      %{document: document, blocks: [block | _rest]} = document_with_blocks(["Original"])
      start_session!(document)

      actor = insert(:actor)

      {:ok, %{proposal: keeper}} =
        Session.propose(document.id, block.block_id, insert(:conversation).id, actor.id, "Kept")

      {:ok, %{proposal: loser}} =
        Session.propose(
          document.id,
          block.block_id,
          insert(:conversation).id,
          actor.id,
          "Dropped"
        )

      assert {:error, :unresolved_contention, _details} =
               Session.commit(document.id, %{
                 actor_id: actor.id,
                 base_revision_id: latest_revision_id(document),
                 block_ids: [block.block_id]
               })

      assert {:ok, _adopted} =
               Session.decide(document.id, block.block_id, keeper.id, actor.id)

      assert {:ok, revision} =
               Session.commit(document.id, %{
                 actor_id: actor.id,
                 base_revision_id: latest_revision_id(document)
               })

      assert [%{content: "Kept"}] = Documents.get_revision!(document, revision.id).blocks
      assert Repo.get!(BlockProposal, loser.id).status == :rejected
      assert Repo.get!(BlockProposal, keeper.id).status == :accepted
    end

    test "the session sees the new revision after committing" do
      %{document: document, blocks: [block | _rest]} = document_with_blocks(["Original"])
      start_session!(document)

      actor = insert(:actor)
      conversation = insert(:conversation)

      {:ok, _} = Session.propose(document.id, block.block_id, conversation.id, actor.id, "New")

      {:ok, revision} =
        Session.commit(document.id, %{
          actor_id: actor.id,
          base_revision_id: latest_revision_id(document)
        })

      # Reads follow the commit because nothing is held between calls. Were
      # anything cached, this is where it would start lying -- and the next
      # commit would go out against a revision that is no longer the latest.
      assert {:ok, [seen]} = Session.get_blocks(document.id, conversation.id)
      assert seen.content == "New"
      refute seen.proposed?

      assert {:ok, _next} =
               Session.propose(document.id, block.block_id, conversation.id, actor.id, "Again")

      assert {:ok, _second_revision} =
               Session.commit(document.id, %{
                 actor_id: actor.id,
                 base_revision_id: revision.id
               })
    end

    test "discarding ends the session and leaves the proposals" do
      %{document: document, blocks: [block | _rest]} = document_with_blocks(["Original"])
      start_session!(document)

      {:ok, %{proposal: proposal}} =
        Session.propose(
          document.id,
          block.block_id,
          insert(:conversation).id,
          insert(:actor).id,
          "Kept in the database"
        )

      assert :ok = Session.discard(document.id)
      refute Session.open?(document.id)

      assert Repo.get!(BlockProposal, proposal.id).status == :live
    end

    test "discarding a session that is not open is fine" do
      assert :ok = Session.discard(UUIDv7.generate())
    end
  end

  # The session runs in its own process, so it needs its own access to the
  # test's sandboxed connection.
  defp start_session!(document) do
    {:ok, pid} = Session.Supervisor.start_session(document_id: document.id)
    Sandbox.allow(RintoPMO.Repo, self(), pid)
    on_exit(fn -> Session.discard(document.id) end)
    pid
  end

  defp document_with_blocks(contents) do
    actor = insert(:actor)

    {:ok, document} =
      Documents.create_document(%{
        title: "Document",
        blocks: Enum.map(contents, &%{actor_id: actor.id, content: &1})
      })

    %{document: document, blocks: Enum.sort_by(document.latest_revision.blocks, & &1.position)}
  end

  defp latest_revision_id(document) do
    Documents.get_document!(document.id).latest_revision.id
  end
end
