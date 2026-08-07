defmodule RintoPMOWeb.V1.BlockProposalControllerTest do
  use RintoPMOWeb.ConnCase, async: true

  alias RintoPMO.DocumentsMock

  setup do
    document = insert(:document)

    stub(DocumentsMock, :get_document!, fn id ->
      assert id == document.id
      document
    end)

    %{document: document}
  end

  test "GET proposals lists them", %{conn: conn, document: document} do
    proposal = insert(:block_proposal, document: document, content: "Tighter")
    proposal_id = proposal.id

    expect(DocumentsMock, :list_proposals, fn ^document, %{} -> [proposal] end)

    conn = get(conn, ~p"/api/v1/documents/#{document.id}/proposals")

    assert [%{"id" => ^proposal_id, "content" => "Tighter", "status" => "live"}] =
             json_response(conn, 200)["data"]
  end

  test "GET proposals filters by status and conversation", %{conn: conn, document: document} do
    conversation = insert(:conversation)
    conversation_id = conversation.id

    expect(DocumentsMock, :list_proposals, fn ^document,
                                              %{
                                                status: :rejected,
                                                conversation_id: ^conversation_id
                                              } ->
      []
    end)

    conn =
      get(
        conn,
        ~p"/api/v1/documents/#{document.id}/proposals?status=rejected&conversation_id=#{conversation.id}"
      )

    assert json_response(conn, 200)["data"] == []
  end

  test "GET proposals rejects an unknown status", %{conn: conn, document: document} do
    conn = get(conn, ~p"/api/v1/documents/#{document.id}/proposals?status=nope")

    assert %{"error" => "bad_request", "details" => %{"status" => ["is invalid"]}} =
             json_response(conn, 400)
  end

  test "POST proposals reports standing alone", %{conn: conn, document: document} do
    proposal = insert(:block_proposal, document: document)

    expect(DocumentsMock, :propose_block, fn ^document, attrs ->
      assert attrs["content"] == "Rewritten"
      {:ok, %{proposal: proposal, live_proposals: 1}}
    end)

    conn =
      post(conn, ~p"/api/v1/documents/#{document.id}/proposals", %{
        "block_id" => proposal.block_id,
        "conversation_id" => proposal.conversation_id,
        "actor_id" => proposal.actor_id,
        "content" => "Rewritten"
      })

    assert %{"live_proposals" => 1, "contended" => false} = json_response(conn, 201)
  end

  test "POST proposals says when it has walked into a contention", %{
    conn: conn,
    document: document
  } do
    proposal = insert(:block_proposal, document: document)

    expect(DocumentsMock, :propose_block, fn ^document, _attrs ->
      {:ok, %{proposal: proposal, live_proposals: 2}}
    end)

    conn =
      post(conn, ~p"/api/v1/documents/#{document.id}/proposals", %{
        "block_id" => proposal.block_id,
        "conversation_id" => proposal.conversation_id,
        "actor_id" => proposal.actor_id,
        "content" => "Mine"
      })

    assert %{"live_proposals" => 2, "contended" => true} = json_response(conn, 201)
  end

  test "POST proposals cannot set status or a decision", %{conn: conn, document: document} do
    proposal = insert(:block_proposal, document: document)

    expect(DocumentsMock, :propose_block, fn ^document, attrs ->
      # A proposal's status moves only by deciding or committing, so the
      # payload is stripped before it reaches the context.
      refute Map.has_key?(attrs, "status")
      refute Map.has_key?(attrs, "decided_by_actor_id")
      {:ok, %{proposal: proposal, live_proposals: 1}}
    end)

    conn =
      post(conn, ~p"/api/v1/documents/#{document.id}/proposals", %{
        "block_id" => proposal.block_id,
        "conversation_id" => proposal.conversation_id,
        "actor_id" => proposal.actor_id,
        "content" => "Mine",
        "status" => "accepted",
        "decided_by_actor_id" => insert(:actor).id
      })

    assert json_response(conn, 201)
  end

  test "POST proposals surfaces an unknown block", %{conn: conn, document: document} do
    block_id = UUIDv7.generate()

    expect(DocumentsMock, :propose_block, fn ^document, _attrs ->
      {:error, :unknown_block, %{block_id: block_id}}
    end)

    conn =
      post(conn, ~p"/api/v1/documents/#{document.id}/proposals", %{
        "block_id" => block_id,
        "conversation_id" => insert(:conversation).id,
        "actor_id" => insert(:actor).id,
        "content" => "Nowhere"
      })

    assert %{"error" => "unknown_block"} = json_response(conn, 422)
  end

  test "GET contentions lists the contended blocks", %{conn: conn, document: document} do
    proposals = insert_pair(:block_proposal, document: document)
    block_id = UUIDv7.generate()

    expect(DocumentsMock, :contentions, fn ^document ->
      [%{block_id: block_id, proposals: proposals}]
    end)

    conn = get(conn, ~p"/api/v1/documents/#{document.id}/contentions")

    assert [%{"block_id" => ^block_id, "proposals" => [_first, _second]}] =
             json_response(conn, 200)["data"]
  end

  test "GET a topic's blocks withholds the other text", %{conn: conn, document: document} do
    conversation = insert(:conversation)
    conversation_id = conversation.id
    block_id = UUIDv7.generate()

    expect(DocumentsMock, :blocks_for_conversation, fn ^document, ^conversation_id ->
      [
        %{
          block_id: block_id,
          position: 0,
          content: "My version",
          proposal_id: nil,
          proposed?: true,
          other_proposals: 2
        }
      ]
    end)

    conn =
      get(conn, ~p"/api/v1/documents/#{document.id}/conversations/#{conversation.id}/blocks")

    assert [block] = json_response(conn, 200)["data"]
    assert block["content"] == "My version"
    assert block["proposed"] == true
    assert block["other_proposals"] == 2
    # The count is the whole point; the rival text is deliberately absent.
    refute Map.has_key?(block, "other_contents")
  end

  test "POST decide adopts a proposal", %{conn: conn, document: document} do
    proposal = insert(:block_proposal, document: document)
    actor = insert(:actor)
    actor_id = actor.id
    proposal_id = proposal.id
    block_id = proposal.block_id

    expect(DocumentsMock, :get_proposal!, fn ^document, id ->
      assert id == proposal.id
      proposal
    end)

    expect(DocumentsMock, :decide_block, fn ^document, ^block_id, ^proposal_id, ^actor_id ->
      {:ok, proposal}
    end)

    conn =
      post(conn, ~p"/api/v1/documents/#{document.id}/proposals/#{proposal.id}/decide", %{
        "actor_id" => actor.id
      })

    assert %{"id" => ^proposal_id, "status" => "live"} = json_response(conn, 200)["data"]
  end

  test "POST decide requires an actor", %{conn: conn, document: document} do
    proposal = insert(:block_proposal, document: document)

    expect(DocumentsMock, :get_proposal!, fn ^document, _id -> proposal end)

    conn = post(conn, ~p"/api/v1/documents/#{document.id}/proposals/#{proposal.id}/decide", %{})

    assert %{"error" => "bad_request", "details" => %{"actor_id" => ["is invalid"]}} =
             json_response(conn, 400)
  end

  test "there is no route to edit or delete a proposal", %{conn: conn, document: document} do
    proposal = insert(:block_proposal, document: document)
    path = "/api/v1/documents/#{document.id}/proposals/#{proposal.id}"

    assert patch(conn, path, %{}).status == 404
    assert delete(conn, path).status == 404
  end
end
