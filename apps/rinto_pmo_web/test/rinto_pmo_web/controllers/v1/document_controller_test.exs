defmodule RintoPMOWeb.V1.DocumentControllerTest do
  use RintoPMOWeb.ConnCase, async: true

  alias RintoPMO.DocumentsMock

  test "GET /api/v1/documents lists all document summaries", %{conn: conn} do
    document = document_with_revision()

    expect(DocumentsMock, :list_documents, fn %{} = filter ->
      assert filter == %{}
      [document]
    end)

    conn = get(conn, ~p"/api/v1/documents")

    assert [data] = json_response(conn, 200)["data"]
    assert data["id"] == document.id
    assert data["fleeting"] == true
    assert data["latest_revision"]["title"] == "Plan"
    refute Map.has_key?(data["latest_revision"], "blocks")
  end

  test "GET /api/v1/documents filters by project id", %{conn: conn} do
    project = insert(:project)

    expect(DocumentsMock, :list_documents, fn %{project: project_id} ->
      assert project_id == project.id
      []
    end)

    conn = get(conn, ~p"/api/v1/documents?project_id=#{project.id}")
    assert json_response(conn, 200)["data"] == []
  end

  test "GET /api/v1/documents filters unassigned documents", %{conn: conn} do
    expect(DocumentsMock, :list_documents, fn %{project: :unassigned} -> [] end)

    conn = get(conn, ~p"/api/v1/documents?project_id=none")
    assert json_response(conn, 200)["data"] == []
  end

  test "GET /api/v1/documents filters on fleeting, alongside the project", %{conn: conn} do
    project = insert(:project)

    expect(DocumentsMock, :list_documents, fn filter ->
      assert filter == %{project: project.id, fleeting: true}
      []
    end)

    conn = get(conn, ~p"/api/v1/documents?project_id=#{project.id}&fleeting=true")
    assert json_response(conn, 200)["data"] == []

    expect(DocumentsMock, :list_documents, fn filter ->
      assert filter == %{fleeting: false}
      []
    end)

    conn = get(conn, ~p"/api/v1/documents?fleeting=false")
    assert json_response(conn, 200)["data"] == []
  end

  test "GET /api/v1/documents rejects a fleeting filter that is not a boolean", %{conn: conn} do
    conn = get(conn, ~p"/api/v1/documents?fleeting=maybe")

    assert %{
             "error" => "bad_request",
             "details" => %{"fleeting" => ["is invalid"]}
           } = json_response(conn, 400)
  end

  test "GET /api/v1/documents rejects an invalid project id", %{conn: conn} do
    conn = get(conn, ~p"/api/v1/documents?project_id=invalid")

    assert %{
             "error" => "bad_request",
             "details" => %{"project_id" => ["is invalid"]}
           } = json_response(conn, 400)
  end

  test "GET /api/v1/documents/:id returns the latest blocks", %{conn: conn} do
    document = insert(:document)
    revision = insert(:document_revision, document: document)
    block = insert(:document_block, revision: revision)
    revision = %{revision | blocks: [block]}
    document = %{document | latest_revision: revision}

    expect(DocumentsMock, :get_document!, fn id ->
      assert id == document.id
      document
    end)

    conn = get(conn, ~p"/api/v1/documents/#{document.id}")

    assert %{"latest_revision" => %{"blocks" => [rendered_block]}} =
             json_response(conn, 200)["data"]

    assert rendered_block["block_id"] == block.block_id
    refute Map.has_key?(rendered_block, "id")
  end

  test "POST /api/v1/documents creates an unassigned document", %{conn: conn} do
    document = insert(:document, project: nil)
    revision = insert(:document_revision, document: document, title: "Draft")
    revision = %{revision | blocks: []}
    document = %{document | latest_revision: revision}
    params = %{"title" => "Draft"}

    expect(DocumentsMock, :create_document, fn ^params -> {:ok, document} end)

    conn = post(conn, ~p"/api/v1/documents", params)

    assert %{
             "project_id" => nil,
             "latest_revision" => %{"title" => "Draft", "blocks" => []}
           } = json_response(conn, 201)["data"]
  end

  test "POST /api/v1/documents passes the Markdown body through to the context", %{conn: conn} do
    document = document_with_revision()
    params = %{"title" => "Plan", "actor_id" => document.id, "markdown" => "## One\n\ntext"}

    expect(DocumentsMock, :create_document, fn ^params -> {:ok, document} end)

    conn = post(conn, ~p"/api/v1/documents", params)

    assert json_response(conn, 201)["data"]["id"] == document.id
  end

  test "POST /api/v1/documents/preview_blocks reports the split", %{conn: conn} do
    expect(DocumentsMock, :preview_blocks, fn markdown ->
      assert markdown == "## One\n\ntext\n\n## Two"
      {:ok, ["## One\n\ntext", "## Two"]}
    end)

    conn =
      post(conn, ~p"/api/v1/documents/preview_blocks", %{
        "markdown" => "## One\n\ntext\n\n## Two"
      })

    assert %{"blocks" => blocks} = json_response(conn, 200)["data"]

    assert blocks == [
             %{"position" => 0, "content" => "## One\n\ntext"},
             %{"position" => 1, "content" => "## Two"}
           ]
  end

  test "POST /api/v1/documents/preview_blocks without a body is a bad request", %{conn: conn} do
    conn = post(conn, ~p"/api/v1/documents/preview_blocks", %{})

    assert %{"error" => "bad_request", "details" => %{"markdown" => ["can't be blank"]}} =
             json_response(conn, 400)
  end

  test "POST /api/v1/documents/:id/formalize adopts a fleeting document", %{conn: conn} do
    document = document_with_revision()
    fleeting = %{document | fleeting: true}
    formal = %{document | fleeting: false}

    expect(DocumentsMock, :get_document!, fn id ->
      assert id == document.id
      fleeting
    end)

    expect(DocumentsMock, :formalize_document, fn ^fleeting -> {:ok, formal} end)

    conn = post(conn, ~p"/api/v1/documents/#{document.id}/formalize")

    assert json_response(conn, 200)["data"]["fleeting"] == false
  end

  test "DELETE /api/v1/documents/:id archives idempotently", %{conn: conn} do
    document = document_with_revision()
    archived = %{document | archived_at: DateTime.utc_now()}

    expect(DocumentsMock, :get_document!, fn id ->
      assert id == document.id
      document
    end)

    expect(DocumentsMock, :archive_document, fn ^document -> {:ok, archived} end)

    conn = delete(conn, ~p"/api/v1/documents/#{document.id}")

    assert response(conn, 204) == ""
  end

  # The rest of this file mocks the context to test the controller alone. These
  # two run the real one, because importing a document is the one flow where
  # the wiring is the feature: a body posted as one string has to come back as
  # the blocks the server decided to cut it into.
  describe "importing a Markdown body end to end" do
    setup do
      stub_with(DocumentsMock, RintoPMO.Documents)
      :ok
    end

    test "POST /api/v1/documents cuts the body into blocks", %{conn: conn} do
      actor = insert(:actor)

      conn =
        post(conn, ~p"/api/v1/documents", %{
          "title" => "Plan",
          "actor_id" => actor.id,
          "markdown" => "preamble\n\n## Background\n\nContext\n\n### Detail\n\nMore"
        })

      assert %{"latest_revision" => %{"title" => "Plan", "blocks" => blocks}} =
               json_response(conn, 201)["data"]

      assert Enum.map(blocks, & &1["content"]) == [
               "preamble",
               "## Background\n\nContext",
               "### Detail\n\nMore"
             ]

      assert Enum.map(blocks, & &1["position"]) == [0, 1, 2]
      assert Enum.all?(blocks, &(&1["actor_id"] == actor.id))
    end

    test "POST /api/v1/documents/preview_blocks agrees with what create would do", %{conn: conn} do
      markdown = "# One\n\nfirst\n\n## Two\n\nsecond"
      actor = insert(:actor)

      preview =
        conn
        |> post(~p"/api/v1/documents/preview_blocks", %{"markdown" => markdown})
        |> json_response(200)

      created =
        conn
        |> post(~p"/api/v1/documents", %{
          "title" => "Plan",
          "actor_id" => actor.id,
          "markdown" => markdown
        })
        |> json_response(201)

      assert Enum.map(preview["data"]["blocks"], & &1["content"]) ==
               Enum.map(created["data"]["latest_revision"]["blocks"], & &1["content"])
    end
  end

  defp document_with_revision do
    document = insert(:document)
    revision = insert(:document_revision, document: document, title: "Plan")
    %{document | latest_revision: %{revision | blocks: []}}
  end
end
