defmodule RintoPMOWeb.V1.DocumentRevisionControllerTest do
  use RintoPMOWeb.ConnCase, async: true

  alias RintoPMO.DocumentsMock

  test "GET revisions lists immutable revision summaries", %{conn: conn} do
    document = expect_document()
    revision = document.latest_revision

    expect(DocumentsMock, :list_revisions, fn ^document -> [revision] end)

    conn = get(conn, ~p"/api/v1/documents/#{document.id}/revisions")

    assert [%{"id" => id, "title" => "Draft"} = data] = json_response(conn, 200)["data"]
    assert id == revision.id
    refute Map.has_key?(data, "blocks")
  end

  test "GET revisions/:revision_id shows ordered blocks", %{conn: conn} do
    document = expect_document()
    revision = document.latest_revision
    block = insert(:document_block, revision: revision)
    revision = %{revision | blocks: [block]}

    expect(DocumentsMock, :get_revision!, fn ^document, id ->
      assert id == revision.id
      revision
    end)

    conn = get(conn, ~p"/api/v1/documents/#{document.id}/revisions/#{revision.id}")

    assert %{"blocks" => [%{"block_id" => block_id}]} = json_response(conn, 200)["data"]
    assert block_id == block.block_id
  end

  test "POST revisions creates a new snapshot", %{conn: conn} do
    document = expect_document()
    parent = document.latest_revision
    revision = insert_revision_after(parent, document: document, title: parent.title)
    revision = %{revision | blocks: []}

    params = %{
      "base_revision_id" => parent.id,
      "block_ops" => []
    }

    expect(DocumentsMock, :create_revision, fn ^document, ^params -> {:ok, revision} end)

    conn = post(conn, ~p"/api/v1/documents/#{document.id}/revisions", params)

    assert %{"id" => id, "parent_id" => parent_id, "blocks" => []} =
             json_response(conn, 201)["data"]

    assert id == revision.id
    assert parent_id == parent.id
  end

  # Writing a revision is how a person changes a document, so every block it
  # touches is theirs -- whatever each operation said.
  test "POST revisions credits every operation to the caller", %{
    conn: conn,
    current_actor: current_actor
  } do
    document = expect_document()
    parent = document.latest_revision
    revision = %{insert_revision_after(parent, document: document) | blocks: []}
    impostor = insert(:actor)
    actor_id = current_actor.id

    expect(DocumentsMock, :create_revision, fn ^document, attrs ->
      assert Enum.all?(attrs["block_ops"], &(&1["actor_id"] == actor_id))
      {:ok, revision}
    end)

    conn =
      post(conn, ~p"/api/v1/documents/#{document.id}/revisions", %{
        "base_revision_id" => parent.id,
        "block_ops" => [
          %{
            "op" => "update",
            "block_id" => UUIDv7.generate(),
            "actor_id" => impostor.id,
            "content" => "Tighter"
          },
          %{"op" => "insert_after", "after_block_id" => nil, "content" => "New"}
        ]
      })

    assert json_response(conn, 201)["data"]["id"] == revision.id
  end

  # A `block_ops` that is not a list is the context's error to name; rewriting
  # it here would turn one bad shape into a different bad shape.
  test "POST revisions leaves a malformed block_ops for the context to refuse", %{conn: conn} do
    document = expect_document()

    expect(DocumentsMock, :create_revision, fn ^document, attrs ->
      assert attrs["block_ops"] == "not a list"
      {:error, :invalid_block_op, %{index: nil}}
    end)

    conn =
      post(conn, ~p"/api/v1/documents/#{document.id}/revisions", %{
        "base_revision_id" => document.latest_revision.id,
        "block_ops" => "not a list"
      })

    assert %{"error" => "invalid_block_op"} = json_response(conn, 422)
  end

  test "POST revisions renders stale document conflicts", %{conn: conn} do
    document = expect_document()
    current_revision_id = document.latest_revision.id
    params = %{"base_revision_id" => UUIDv7.generate(), "block_ops" => []}

    expect(DocumentsMock, :create_revision, fn ^document, ^params ->
      {:error, :stale_document, %{current_revision_id: current_revision_id}}
    end)

    conn = post(conn, ~p"/api/v1/documents/#{document.id}/revisions", params)

    assert %{
             "error" => "stale_document",
             "details" => %{"current_revision_id" => ^current_revision_id}
           } = json_response(conn, 409)
  end

  test "POST commit turns the named proposals into a revision", %{
    conn: conn,
    current_actor: current_actor
  } do
    document = expect_document()
    conversation = insert(:conversation)
    annotation = insert(:annotation, document: document)
    taken = insert(:block_proposal, document: document)
    beaten = insert(:block_proposal, document: document, block_id: taken.block_id)

    revision =
      insert_revision_after(document.latest_revision,
        document: document,
        change_summary: "Tightened §3",
        source_conversation: conversation
      )

    revision_id = revision.id
    conversation_id = conversation.id
    taken_id = taken.id
    beaten_id = beaten.id

    params = %{
      "base_revision_id" => document.latest_revision.id,
      "proposal_ids" => [taken.id],
      "source_conversation_id" => conversation.id,
      "confirm_annotation_ids" => [annotation.id],
      "change_summary" => "Tightened §3"
    }

    # Publishing is a person's action, so the actor is the token's rather than
    # anything the body said.
    expected = Map.put(params, "actor_id", current_actor.id)

    expect(DocumentsMock, :commit_proposals, fn ^document, ^expected ->
      {:ok,
       %{
         result: :published,
         revision: %{revision | blocks: []},
         current_revision_id: revision.id,
         document_id: document.id,
         accepted: [taken.id],
         superseded: [beaten.id],
         already_applied: []
       }}
    end)

    conn = post(conn, ~p"/api/v1/documents/#{document.id}/commit", params)

    response = json_response(conn, 201)

    assert %{
             "id" => ^revision_id,
             "change_summary" => "Tightened §3",
             "source_conversation_id" => ^conversation_id
           } = response["data"]

    # What happened to each proposal, because "it worked" is not enough to
    # redraw a review screen with.
    assert response["meta"]["result"] == "published"
    assert response["meta"]["accepted_proposal_ids"] == [taken_id]
    assert response["meta"]["superseded_proposal_ids"] == [beaten_id]
  end

  # Nothing to do is not an empty revision. It writes nothing, says so, and
  # marks nobody as accepted -- no publish applied these.
  test "POST commit answers 200 with no revision when everything is already true", %{conn: conn} do
    document = expect_document()
    proposal = insert(:block_proposal, document: document)
    proposal_id = proposal.id
    revision_id = document.latest_revision.id

    expect(DocumentsMock, :commit_proposals, fn ^document, _attrs ->
      {:ok,
       %{
         result: :already_applied,
         revision: nil,
         current_revision_id: revision_id,
         document_id: document.id,
         accepted: [],
         superseded: [],
         already_applied: [proposal.id]
       }}
    end)

    conn =
      post(conn, ~p"/api/v1/documents/#{document.id}/commit", %{
        "base_revision_id" => revision_id,
        "proposal_ids" => [proposal.id]
      })

    response = json_response(conn, 200)

    assert response["data"] == nil
    assert response["meta"]["result"] == "already_applied"
    assert response["meta"]["already_applied_proposal_ids"] == [proposal_id]
  end

  test "POST commit refuses two proposals that claim the same thing", %{conn: conn} do
    document = expect_document()
    proposal_ids = [UUIDv7.generate(), UUIDv7.generate()]
    params = %{"base_revision_id" => UUIDv7.generate(), "proposal_ids" => proposal_ids}

    expect(DocumentsMock, :commit_proposals, fn ^document, _attrs ->
      {:error, :conflicting_selection,
       %{conflicts: [%{proposal_ids: proposal_ids, reason: :competing_text}]}}
    end)

    conn = post(conn, ~p"/api/v1/documents/#{document.id}/commit", params)

    # Picking one of them is the decision this system leaves to a person, and
    # doing it here would do it invisibly.
    assert %{"error" => "conflicting_selection", "details" => %{"conflicts" => [_pair]}} =
             json_response(conn, 422)
  end

  test "POST commit reports having nothing to commit", %{conn: conn} do
    document = expect_document()
    params = %{"base_revision_id" => UUIDv7.generate(), "proposal_ids" => []}

    expect(DocumentsMock, :commit_proposals, fn ^document, _attrs ->
      {:error, :nothing_to_commit, %{}}
    end)

    conn = post(conn, ~p"/api/v1/documents/#{document.id}/commit", params)

    assert %{"error" => "nothing_to_commit"} = json_response(conn, 422)
  end

  defp expect_document do
    document = insert(:document)
    revision = insert(:document_revision, document: document, title: "Draft")
    document = %{document | latest_revision: %{revision | blocks: []}}

    expect(DocumentsMock, :get_document!, fn id ->
      assert id == document.id
      document
    end)

    document
  end
end
