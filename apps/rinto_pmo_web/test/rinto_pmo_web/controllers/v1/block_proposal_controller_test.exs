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

    expect(DocumentsMock, :scope_contentions, fn ^document -> [] end)

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

    expect(DocumentsMock, :document_proposal_for_conversation, fn ^document, ^conversation_id ->
      nil
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

  # Beside the blocks, not among them: a rewrite is not a per-block overlay, and
  # rendering it as one would mean inventing ids for text that has none yet.
  test "GET a topic's blocks reports its whole-document rewrite alongside them", %{
    conn: conn,
    document: document
  } do
    conversation = insert(:conversation)
    conversation_id = conversation.id

    proposal =
      insert(:block_proposal,
        document: document,
        scope: :document,
        block_id: nil,
        block_ops: [%{"op" => "delete", "block_id" => UUIDv7.generate()}]
      )

    proposal_id = proposal.id

    expect(DocumentsMock, :blocks_for_conversation, fn ^document, ^conversation_id -> [] end)

    expect(DocumentsMock, :document_proposal_for_conversation, fn ^document, ^conversation_id ->
      proposal
    end)

    conn =
      get(conn, ~p"/api/v1/documents/#{document.id}/conversations/#{conversation.id}/blocks")

    assert %{"id" => ^proposal_id, "scope" => "document", "block_ops" => [_only]} =
             json_response(conn, 200)["document_proposal"]
  end

  test "GET contentions reports document-level arguments separately", %{
    conn: conn,
    document: document
  } do
    titles = insert_pair(:block_proposal, document: document, scope: :title, block_id: nil)

    expect(DocumentsMock, :contentions, fn ^document -> [] end)

    expect(DocumentsMock, :scope_contentions, fn ^document ->
      [%{scope: :title, proposals: titles}]
    end)

    conn = get(conn, ~p"/api/v1/documents/#{document.id}/contentions")

    # Not in `data`: these cannot be marked on a block, and no per-block
    # decision would settle them.
    assert json_response(conn, 200)["data"] == []

    assert [%{"scope" => "title", "proposals" => [_first, _second]}] =
             json_response(conn, 200)["document_scopes"]
  end

  # Deciding is the one thing only a person does, so who decided is the token
  # holder and an `actor_id` in the body is ignored rather than believed.
  test "POST decide adopts a proposal, stamped by the token holder", %{
    conn: conn,
    document: document,
    current_actor: actor
  } do
    proposal = insert(:block_proposal, document: document)
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
        "actor_id" => insert(:actor).id
      })

    assert %{"id" => ^proposal_id, "status" => "live"} = json_response(conn, 200)["data"]
  end

  test "POST proposals routes a title scope to its own slot", %{conn: conn, document: document} do
    proposal = insert(:block_proposal, document: document, scope: :title, block_id: nil)

    expect(DocumentsMock, :propose_title, fn ^document, attrs ->
      assert attrs["content"] == "上线流程"
      # A block cannot be named here, so one sent anyway is dropped rather than
      # passed on to be rejected.
      refute Map.has_key?(attrs, "block_id")
      {:ok, %{proposal: proposal, live_proposals: 1}}
    end)

    conn =
      post(conn, ~p"/api/v1/documents/#{document.id}/proposals", %{
        "scope" => "title",
        "block_id" => UUIDv7.generate(),
        "conversation_id" => proposal.conversation_id,
        "actor_id" => proposal.actor_id,
        "content" => "上线流程"
      })

    assert %{"scope" => "title", "block_id" => nil} = json_response(conn, 201)["data"]
  end

  # An operation list is compiled from Markdown, never sent in. A caller able to
  # supply its own could write a revision no Markdown produces.
  test "POST proposals ignores block operations sent by a client", %{
    conn: conn,
    document: document
  } do
    proposal = insert(:block_proposal, document: document)

    expect(DocumentsMock, :propose_block, fn ^document, attrs ->
      refute Map.has_key?(attrs, "block_ops")
      {:ok, %{proposal: proposal, live_proposals: 1}}
    end)

    conn =
      post(conn, ~p"/api/v1/documents/#{document.id}/proposals", %{
        "block_id" => proposal.block_id,
        "conversation_id" => proposal.conversation_id,
        "actor_id" => proposal.actor_id,
        "content" => "Rewritten",
        "block_ops" => [%{"op" => "delete", "block_id" => UUIDv7.generate()}]
      })

    assert json_response(conn, 201)
  end

  test "POST proposals routes a document scope and returns the compiled diff", %{
    conn: conn,
    document: document
  } do
    operations = [%{"op" => "insert_after", "after_block_id" => nil, "content" => "## New"}]

    proposal =
      insert(:block_proposal,
        document: document,
        scope: :document,
        block_id: nil,
        content: "## New\n\n## Old",
        block_ops: operations,
        change_summary: "Added an intro"
      )

    expect(DocumentsMock, :propose_document, fn ^document, attrs ->
      assert attrs["content"] == "## New\n\n## Old"
      assert attrs["change_summary"] == "Added an intro"
      {:ok, %{proposal: proposal, live_proposals: 1}}
    end)

    conn =
      post(conn, ~p"/api/v1/documents/#{document.id}/proposals", %{
        "scope" => "document",
        "conversation_id" => proposal.conversation_id,
        "actor_id" => proposal.actor_id,
        "content" => "## New\n\n## Old",
        "change_summary" => "Added an intro"
      })

    # The operations come back so a client can show the diff a person is being
    # asked to approve, rather than two bodies to compare by eye.
    assert %{
             "scope" => "document",
             "block_ops" => ^operations,
             "change_summary" => "Added an intro"
           } = json_response(conn, 201)["data"]
  end

  test "POST proposals refuses a scope it does not serve", %{conn: conn, document: document} do
    conn =
      post(conn, ~p"/api/v1/documents/#{document.id}/proposals", %{
        "scope" => "wormhole",
        "conversation_id" => insert(:conversation).id,
        "actor_id" => insert(:actor).id,
        "content" => "Anything"
      })

    assert %{"error" => "invalid_scope", "details" => %{"scope" => "wormhole"}} =
             json_response(conn, 422)
  end

  # The proposal says which argument it is in, so a client deciding one names a
  # proposal and nothing else -- the same call it made before scopes existed.
  test "POST decide settles a title from the proposal alone", %{
    conn: conn,
    document: document,
    current_actor: actor
  } do
    proposal = insert(:block_proposal, document: document, scope: :title, block_id: nil)
    actor_id = actor.id
    proposal_id = proposal.id

    expect(DocumentsMock, :get_proposal!, fn ^document, _id -> proposal end)

    expect(DocumentsMock, :decide_title, fn ^document, ^proposal_id, ^actor_id ->
      {:ok, proposal}
    end)

    conn =
      post(conn, ~p"/api/v1/documents/#{document.id}/proposals/#{proposal.id}/decide", %{})

    assert %{"id" => ^proposal_id, "scope" => "title"} = json_response(conn, 200)["data"]
  end

  test "POST rebase carries a proposal across what landed under it", %{
    conn: conn,
    document: document
  } do
    proposal = insert(:block_proposal, document: document, scope: :document, block_id: nil)
    proposal_id = proposal.id

    expect(DocumentsMock, :rebase_document_proposal, fn ^document, ^proposal_id ->
      {:ok, proposal}
    end)

    conn = post(conn, ~p"/api/v1/documents/#{document.id}/proposals/#{proposal.id}/rebase")

    assert %{"id" => ^proposal_id, "scope" => "document"} = json_response(conn, 200)["data"]
  end

  test "POST rebase surfaces a conflict for a person to decide", %{
    conn: conn,
    document: document
  } do
    proposal = insert(:block_proposal, document: document, scope: :document, block_id: nil)
    block_id = UUIDv7.generate()

    expect(DocumentsMock, :rebase_document_proposal, fn ^document, _id ->
      {:error, :rebase_conflict, %{reason: :diverged, block_ids: [block_id]}}
    end)

    conn = post(conn, ~p"/api/v1/documents/#{document.id}/proposals/#{proposal.id}/rebase")

    assert %{"error" => "rebase_conflict", "details" => %{"block_ids" => [^block_id]}} =
             json_response(conn, 409)
  end

  test "there is no route to edit or delete a proposal", %{conn: conn, document: document} do
    proposal = insert(:block_proposal, document: document)
    path = "/api/v1/documents/#{document.id}/proposals/#{proposal.id}"

    assert patch(conn, path, %{}).status == 404
    assert delete(conn, path).status == 404
  end
end
