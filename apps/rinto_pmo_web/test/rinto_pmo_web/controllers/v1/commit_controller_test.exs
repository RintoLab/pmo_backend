defmodule RintoPMOWeb.V1.CommitControllerTest do
  use RintoPMOWeb.ConnCase, async: true

  alias RintoPMO.DocumentsMock

  test "POST commits writes one revision per document", %{conn: conn} do
    first = insert(:document)
    second = insert(:document)
    conversation = insert(:conversation)
    actor = insert(:actor)

    revisions = [
      insert(:document_revision, document: first, source_conversation: conversation),
      insert(:document_revision, document: second, source_conversation: conversation)
    ]

    [first_revision, second_revision] = Enum.map(revisions, & &1.id)
    expect_documents([first, second])

    expect(DocumentsMock, :commit_many, fn entries ->
      assert Enum.map(entries, fn {document, _attrs} -> document.id end) == [first.id, second.id]

      # `document_id` named the entry; it does not travel on into the attrs,
      # where it would be a second spelling of the document already passed.
      assert Enum.all?(entries, fn {_document, attrs} ->
               not Map.has_key?(attrs, "document_id")
             end)

      {:ok, revisions}
    end)

    conn =
      post(conn, ~p"/api/v1/commits", %{
        "commits" => [
          %{
            "document_id" => first.id,
            "actor_id" => actor.id,
            "source_conversation_id" => conversation.id
          },
          %{
            "document_id" => second.id,
            "actor_id" => actor.id,
            "source_conversation_id" => conversation.id
          }
        ]
      })

    assert [%{"id" => ^first_revision}, %{"id" => ^second_revision}] =
             json_response(conn, 201)["data"]
  end

  # Which document it happened in is the next question after any of these.
  test "POST commits names the document an entry failed in", %{conn: conn} do
    document = insert(:document)
    expect_documents([document])

    expect(DocumentsMock, :commit_many, fn _entries ->
      {:error, :unresolved_contention, %{document_id: document.id}}
    end)

    conn = post(conn, ~p"/api/v1/commits", %{"commits" => [%{"document_id" => document.id}]})

    document_id = document.id

    assert %{
             "error" => "unresolved_contention",
             "details" => %{"document_id" => ^document_id}
           } = json_response(conn, 409)
  end

  test "POST commits refuses the same document twice", %{conn: conn} do
    document = insert(:document)
    expect(DocumentsMock, :get_document!, 2, fn _id -> document end)

    expect(DocumentsMock, :commit_many, fn _entries ->
      {:error, :duplicate_document, %{document_id: document.id}}
    end)

    conn =
      post(conn, ~p"/api/v1/commits", %{
        "commits" => [%{"document_id" => document.id}, %{"document_id" => document.id}]
      })

    assert %{"error" => "duplicate_document"} = json_response(conn, 422)
  end

  test "POST commits needs a non-empty list", %{conn: conn} do
    assert %{"error" => "bad_request"} =
             conn |> post(~p"/api/v1/commits", %{"commits" => []}) |> json_response(400)

    assert %{"error" => "bad_request"} =
             conn |> post(~p"/api/v1/commits", %{}) |> json_response(400)
  end

  test "POST commits needs every entry to name a document", %{conn: conn} do
    conn = post(conn, ~p"/api/v1/commits", %{"commits" => [%{"block_ids" => []}]})

    assert %{"error" => "bad_request", "details" => %{"commits" => [_message]}} =
             json_response(conn, 400)
  end

  # Before a transaction is open, and the same 404 a missing document is
  # everywhere else in this API.
  test "POST commits is 404 when a document is missing", %{conn: conn} do
    expect(DocumentsMock, :get_document!, fn _id ->
      raise Ecto.NoResultsError, queryable: RintoPMO.Documents.Document
    end)

    assert {404, _headers, _body} =
             assert_error_sent(:not_found, fn ->
               post(conn, ~p"/api/v1/commits", %{
                 "commits" => [%{"document_id" => UUIDv7.generate()}]
               })
             end)
  end

  defp expect_documents(documents) do
    by_id = Map.new(documents, &{&1.id, &1})

    expect(DocumentsMock, :get_document!, length(documents), fn id -> Map.fetch!(by_id, id) end)
  end
end
