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

  describe "GET proposals" do
    test "lists them with what each still means", %{conn: conn, document: document} do
      proposal = insert(:block_proposal, document: document, content: "Tighter")
      proposal_id = proposal.id
      revision_id = UUIDv7.generate()

      expect(DocumentsMock, :review_proposals, fn ^document, %{} ->
        {:ok, %{current_revision_id: revision_id, proposals: [detail(proposal)]}}
      end)

      conn = get(conn, ~p"/api/v1/documents/#{document.id}/proposals")
      response = json_response(conn, 200)

      assert [
               %{
                 "id" => ^proposal_id,
                 "content" => "Tighter",
                 "status" => "live",
                 "operation" => "update",
                 "staged" => false,
                 "state" => "applicable",
                 "adopted" => false,
                 "adoption_stale" => false,
                 "conflicting_proposal_ids" => []
               }
             ] = response["data"]

      # The revision the whole list was compared against, from the same read. A
      # client pairing one revision's diff with another revision's id would
      # publish against the wrong thing and never know.
      assert response["meta"]["current_revision_id"] == revision_id
    end

    test "filters by status and conversation", %{conn: conn, document: document} do
      conversation = insert(:conversation)
      conversation_id = conversation.id

      expect(DocumentsMock, :review_proposals, fn ^document,
                                                  %{
                                                    status: :rejected,
                                                    conversation_id: ^conversation_id
                                                  } ->
        {:ok, %{current_revision_id: UUIDv7.generate(), proposals: []}}
      end)

      conn =
        get(
          conn,
          ~p"/api/v1/documents/#{document.id}/proposals?status=rejected&conversation_id=#{conversation.id}"
        )

      assert json_response(conn, 200)["data"] == []
    end

    test "rejects an unknown status", %{conn: conn, document: document} do
      conn = get(conn, ~p"/api/v1/documents/#{document.id}/proposals?status=nope")

      assert %{"error" => "bad_request", "details" => %{"status" => ["is invalid"]}} =
               json_response(conn, 400)
    end
  end

  describe "POST proposals" do
    test "compiles a whole body into the separate changes it is made of", %{
      conn: conn,
      document: document
    } do
      base_revision_id = UUIDv7.generate()
      update = insert(:block_proposal, document: document, content: "## One, tighter")

      insertion =
        insert(:block_proposal,
          document: document,
          operation: :insert,
          content: "## Two",
          after_block_id: update.block_id
        )

      expect(DocumentsMock, :propose_document, fn ^document, attrs ->
        assert attrs["content"] == "## One, tighter\n\n## Two"
        assert attrs["base_revision_id"] == base_revision_id
        refute Map.has_key?(attrs, "block_id")

        {:ok, proposed([update, insertion], %{changed: 1, added: 1, removed: 0, moved: 0})}
      end)

      conn =
        post(conn, ~p"/api/v1/documents/#{document.id}/proposals", %{
          "conversation_id" => UUIDv7.generate(),
          "input" => %{
            "kind" => "document",
            "content" => "## One, tighter\n\n## Two",
            "base_revision_id" => base_revision_id
          }
        })

      response = json_response(conn, 201)

      # No row means "the rewrite". What comes back is what a person will have
      # separate opinions about.
      assert Enum.map(response["data"], & &1["operation"]) == ["update", "insert"]
      assert response["summary"] == %{"changed" => 1, "added" => 1, "removed" => 0, "moved" => 0}
      assert response["contended"] == []
    end

    test "routes a block input to its own slot", %{conn: conn, document: document} do
      proposal = insert(:block_proposal, document: document)
      block_id = proposal.block_id

      expect(DocumentsMock, :propose_block, fn ^document, attrs ->
        assert attrs["block_id"] == block_id
        assert attrs["content"] == "Tighter"
        {:ok, proposed([proposal])}
      end)

      conn =
        post(conn, ~p"/api/v1/documents/#{document.id}/proposals", %{
          "conversation_id" => UUIDv7.generate(),
          "input" => %{
            "kind" => "block",
            "block_id" => block_id,
            "content" => "Tighter",
            "base_revision_id" => UUIDv7.generate()
          }
        })

      assert [%{"scope" => "block"}] = json_response(conn, 201)["data"]
    end

    test "routes a title input to its own slot", %{conn: conn, document: document} do
      proposal =
        insert(:block_proposal, document: document, scope: :title, block_id: nil, content: "Name")

      expect(DocumentsMock, :propose_title, fn ^document, attrs ->
        assert attrs["content"] == "Name"
        refute Map.has_key?(attrs, "block_id")
        {:ok, proposed([proposal])}
      end)

      conn =
        post(conn, ~p"/api/v1/documents/#{document.id}/proposals", %{
          "conversation_id" => UUIDv7.generate(),
          "input" => %{
            "kind" => "title",
            "content" => "Name",
            "base_revision_id" => UUIDv7.generate()
          }
        })

      assert [%{"scope" => "title", "block_id" => nil}] = json_response(conn, 201)["data"]
    end

    test "names every argument it walked into", %{conn: conn, document: document} do
      proposal = insert(:block_proposal, document: document)
      rival = insert(:block_proposal, document: document, block_id: proposal.block_id)
      proposal_id = proposal.id
      rival_id = rival.id

      expect(DocumentsMock, :propose_block, fn ^document, _attrs ->
        {:ok,
         %{
           proposals: [proposal],
           summary: %{changed: 1, added: 0, removed: 0, moved: 0},
           superseded: [],
           contended: [%{proposal_id: proposal.id, conflicting_proposal_ids: [rival.id]}]
         }}
      end)

      conn =
        post(conn, ~p"/api/v1/documents/#{document.id}/proposals", %{
          "conversation_id" => UUIDv7.generate(),
          "input" => %{
            "kind" => "block",
            "block_id" => proposal.block_id,
            "content" => "Tighter",
            "base_revision_id" => UUIDv7.generate()
          }
        })

      assert [%{"proposal_id" => ^proposal_id, "conflicting_proposal_ids" => [^rival_id]}] =
               json_response(conn, 201)["contended"]
    end

    test "refuses an input kind it does not serve", %{conn: conn, document: document} do
      conn =
        post(conn, ~p"/api/v1/documents/#{document.id}/proposals", %{
          "conversation_id" => UUIDv7.generate(),
          "input" => %{
            "kind" => "wormhole",
            "content" => "x",
            "base_revision_id" => UUIDv7.generate()
          }
        })

      assert %{"error" => "invalid_input_kind", "details" => %{"kind" => "wormhole"}} =
               json_response(conn, 422)
    end

    test "refuses a request with no input at all", %{conn: conn, document: document} do
      conn = post(conn, ~p"/api/v1/documents/#{document.id}/proposals", %{"content" => "Tighter"})

      assert %{"error" => "validation_error", "details" => %{"input" => ["is required"]}} =
               json_response(conn, 422)
    end

    test "cannot set state a person's actions write", %{conn: conn, document: document} do
      proposal = insert(:block_proposal, document: document)

      expect(DocumentsMock, :propose_block, fn ^document, attrs ->
        # Nothing but the input reaches the context. Who a proposal is by comes
        # from the topic, and its state comes from what people do to it.
        refute Map.has_key?(attrs, "status")
        refute Map.has_key?(attrs, "staged")
        refute Map.has_key?(attrs, "actor_id")
        refute Map.has_key?(attrs, "decided_by_actor_id")
        {:ok, proposed([proposal])}
      end)

      conn =
        post(conn, ~p"/api/v1/documents/#{document.id}/proposals", %{
          "conversation_id" => UUIDv7.generate(),
          "status" => "accepted",
          "staged" => true,
          "actor_id" => UUIDv7.generate(),
          "decided_by_actor_id" => UUIDv7.generate(),
          "input" => %{
            "kind" => "block",
            "block_id" => proposal.block_id,
            "content" => "Tighter",
            "base_revision_id" => UUIDv7.generate()
          }
        })

      assert json_response(conn, 201)
    end
  end

  describe "PATCH proposals" do
    test "saves the checkbox and nothing else", %{conn: conn, document: document} do
      proposal = insert(:block_proposal, document: document, staged: false)
      proposal_id = proposal.id

      expect(DocumentsMock, :stage_proposal, fn ^document, ^proposal_id, true ->
        {:ok, detail(%{proposal | staged: true})}
      end)

      conn =
        patch(conn, ~p"/api/v1/documents/#{document.id}/proposals/#{proposal.id}", %{
          "staged" => true
        })

      assert %{"staged" => true} = json_response(conn, 200)["data"]
    end

    test "is not a toggle: it takes the value it is given", %{conn: conn, document: document} do
      proposal = insert(:block_proposal, document: document, staged: true)
      proposal_id = proposal.id

      expect(DocumentsMock, :stage_proposal, fn ^document, ^proposal_id, false ->
        {:ok, detail(%{proposal | staged: false})}
      end)

      conn =
        patch(conn, ~p"/api/v1/documents/#{document.id}/proposals/#{proposal.id}", %{
          "staged" => false
        })

      assert %{"staged" => false} = json_response(conn, 200)["data"]
    end

    test "refuses a body that does not say which way", %{conn: conn, document: document} do
      proposal = insert(:block_proposal, document: document)

      conn =
        patch(conn, ~p"/api/v1/documents/#{document.id}/proposals/#{proposal.id}", %{
          "staged" => "yes"
        })

      assert %{"error" => "validation_error", "details" => %{"staged" => _reason}} =
               json_response(conn, 422)
    end

    test "will not rewrite the payload", %{conn: conn, document: document} do
      proposal = insert(:block_proposal, document: document, content: "Original")
      proposal_id = proposal.id

      expect(DocumentsMock, :stage_proposal, fn ^document, ^proposal_id, true ->
        {:ok, detail(%{proposal | staged: true})}
      end)

      conn =
        patch(conn, ~p"/api/v1/documents/#{document.id}/proposals/#{proposal.id}", %{
          "staged" => true,
          "content" => "Something else entirely",
          "status" => "accepted"
        })

      # A proposal id names one modification forever: a message citing it has to
      # keep saying what it said.
      assert %{"content" => "Original", "status" => "live"} = json_response(conn, 200)["data"]
    end
  end

  describe "POST adopt, unadopt and reject" do
    test "adopting is stamped by the token holder and carries what was on screen",
         %{conn: conn, document: document, current_actor: actor} do
      proposal = insert(:block_proposal, document: document)
      proposal_id = proposal.id
      actor_id = actor.id
      revision_id = UUIDv7.generate()

      expect(DocumentsMock, :adopt_proposal, fn ^document,
                                                ^proposal_id,
                                                ^revision_id,
                                                ^actor_id ->
        {:ok, %{detail(proposal) | adopted: true}}
      end)

      conn =
        post(conn, ~p"/api/v1/documents/#{document.id}/proposals/#{proposal.id}/adopt", %{
          "base_revision_id" => revision_id
        })

      assert %{"adopted" => true} = json_response(conn, 200)["data"]
    end

    test "un-adopting takes no revision, because it decides nothing", %{
      conn: conn,
      document: document
    } do
      proposal = insert(:block_proposal, document: document)
      proposal_id = proposal.id

      expect(DocumentsMock, :unadopt_proposal, fn ^document, ^proposal_id ->
        {:ok, detail(proposal)}
      end)

      conn = post(conn, ~p"/api/v1/documents/#{document.id}/proposals/#{proposal.id}/unadopt")

      assert %{"adopted" => false} = json_response(conn, 200)["data"]
    end

    test "rejecting records who said no, and may record why", %{
      conn: conn,
      document: document,
      current_actor: actor
    } do
      proposal = insert(:block_proposal, document: document)
      proposal_id = proposal.id
      actor_id = actor.id

      expect(DocumentsMock, :reject_proposal, fn ^document,
                                                 ^proposal_id,
                                                 ^actor_id,
                                                 "wrong tone" ->
        {:ok,
         detail(%{
           proposal
           | status: :rejected,
             decided_by_actor_id: actor_id,
             decided_reason: "wrong tone"
         })}
      end)

      conn =
        post(conn, ~p"/api/v1/documents/#{document.id}/proposals/#{proposal.id}/reject", %{
          "reason" => "wrong tone"
        })

      assert %{"status" => "rejected", "decided_reason" => "wrong tone"} =
               json_response(conn, 200)["data"]
    end
  end

  describe "GET contentions" do
    test "answers with pairs and what they are arguing about", %{
      conn: conn,
      document: document
    } do
      first = insert(:block_proposal, document: document)
      second = insert(:block_proposal, document: document, block_id: first.block_id)
      ids = [first.id, second.id]

      expect(DocumentsMock, :contentions, fn ^document ->
        [%{reason: :competing_text, proposal_ids: ids, scope: :block, block_id: first.block_id}]
      end)

      conn = get(conn, ~p"/api/v1/documents/#{document.id}/contentions")

      assert [%{"reason" => "competing_text", "proposal_ids" => ^ids, "scope" => "block"}] =
               json_response(conn, 200)["data"]
    end

    test "a title argument is an ordinary one", %{conn: conn, document: document} do
      first = insert(:block_proposal, document: document, scope: :title, block_id: nil)
      second = insert(:block_proposal, document: document, scope: :title, block_id: nil)
      ids = [first.id, second.id]

      expect(DocumentsMock, :contentions, fn ^document ->
        [%{reason: :competing_title, proposal_ids: ids, scope: :title, block_id: nil}]
      end)

      conn = get(conn, ~p"/api/v1/documents/#{document.id}/contentions")

      assert [%{"scope" => "title", "block_id" => nil}] = json_response(conn, 200)["data"]
    end
  end

  describe "GET a topic's blocks" do
    test "withholds the other text and names what could not be laid over", %{
      conn: conn,
      document: document
    } do
      conversation = insert(:conversation)
      conversation_id = conversation.id
      block_id = UUIDv7.generate()
      proposal_id = UUIDv7.generate()
      revision_id = UUIDv7.generate()

      expect(DocumentsMock, :conversation_document_view, fn ^document, ^conversation_id ->
        {:ok,
         %{
           revision_id: revision_id,
           title: "A better name",
           blocks: [
             %{
               block_id: block_id,
               position: 0,
               content: "Mine",
               proposal_id: proposal_id,
               proposed?: true,
               other_proposals: 2
             }
           ],
           unapplicable: [%{proposal_id: UUIDv7.generate(), reason: :target_deleted}]
         }}
      end)

      conn =
        get(conn, ~p"/api/v1/documents/#{document.id}/conversations/#{conversation.id}/blocks")

      response = json_response(conn, 200)

      assert response["revision_id"] == revision_id
      assert response["title"] == "A better name"

      assert [%{"content" => "Mine", "proposed" => true, "other_proposals" => 2}] =
               response["data"]

      refute response |> Jason.encode!() |> String.contains?("Theirs")
      assert [%{"reason" => "target_deleted"}] = response["unapplicable"]
    end
  end

  test "there is no route to delete a proposal", %{conn: conn, document: document} do
    proposal = insert(:block_proposal, document: document)

    # Nothing is ever deleted: a proposal cited by a topic would leave a
    # dangling reference behind, and "why was A chosen over B" is the most
    # valuable thing this records.
    conn = delete(conn, ~p"/api/v1/documents/#{document.id}/proposals/#{proposal.id}")
    assert json_response(conn, 404)["error"] == "not_found"
  end

  defp proposed(proposals, summary \\ %{changed: 1, added: 0, removed: 0, moved: 0}) do
    %{proposals: proposals, summary: summary, superseded: [], contended: []}
  end

  defp detail(proposal) do
    %{
      proposal: proposal,
      state: :applicable,
      reason: nil,
      adopted: false,
      adoption_stale: false,
      conflicting_proposal_ids: [],
      current_revision_id: UUIDv7.generate()
    }
  end
end
