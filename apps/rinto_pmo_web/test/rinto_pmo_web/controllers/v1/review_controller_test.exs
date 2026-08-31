defmodule RintoPMOWeb.V1.ReviewControllerTest do
  use RintoPMOWeb.ConnCase, async: true

  alias RintoPMO.Annotations
  alias RintoPMO.AnnotationsMock
  alias RintoPMO.DocumentsMock

  test "POST reviews answers with the job", %{conn: conn} do
    first = insert(:document)
    second = insert(:document)
    expect_documents([first, second])

    expect(AnnotationsMock, :request_review, fn documents ->
      assert Enum.map(documents, & &1.id) == [first.id, second.id]
      {:ok, queued_job([first.id, second.id])}
    end)

    conn = post(conn, ~p"/api/v1/reviews", %{"document_ids" => [first.id, second.id]})

    assert %{"id" => 42, "status" => "running"} = json_response(conn, 202)["data"]
  end

  test "POST reviews takes one document as a set of one", %{conn: conn} do
    document = insert(:document)
    expect_documents([document])

    expect(AnnotationsMock, :request_review, fn [loaded] ->
      assert loaded.id == document.id
      {:ok, queued_job([document.id])}
    end)

    conn = post(conn, ~p"/api/v1/reviews", %{"document_ids" => [document.id]})

    assert json_response(conn, 202)["data"]
  end

  # A review of a set that was not all there is not the review somebody asked
  # for, so nothing is queued.
  test "POST reviews is 404 when a document is missing", %{conn: conn} do
    document = insert(:document)

    expect(DocumentsMock, :get_document!, fn _id ->
      raise Ecto.NoResultsError, queryable: RintoPMO.Documents.Document
    end)

    assert {404, _headers, body} =
             assert_error_sent(:not_found, fn ->
               post(conn, ~p"/api/v1/reviews", %{"document_ids" => [document.id]})
             end)

    assert %{"error" => "not_found"} = Jason.decode!(body)
  end

  test "POST reviews needs document_ids", %{conn: conn} do
    conn = post(conn, ~p"/api/v1/reviews", %{})

    assert %{"error" => "bad_request"} = json_response(conn, 400)
  end

  test "POST reviews refuses a review of nothing", %{conn: conn} do
    conn = post(conn, ~p"/api/v1/reviews", %{"document_ids" => []})

    assert %{"error" => "no_documents"} = json_response(conn, 422)
  end

  # Refused before anything is loaded: five hundred ids would otherwise be five
  # hundred queries on the way to being told no.
  test "POST reviews refuses more documents than one review carries", %{conn: conn} do
    ids = for _over <- 0..Annotations.max_documents(), do: UUIDv7.generate()

    conn = post(conn, ~p"/api/v1/reviews", %{"document_ids" => ids})

    assert %{"error" => "too_many_documents", "details" => %{"limit" => limit}} =
             json_response(conn, 422)

    assert limit == Annotations.max_documents()
  end

  test "POST reviews says when nobody holds the role", %{conn: conn} do
    document = insert(:document)
    expect_documents([document])

    expect(AnnotationsMock, :request_review, fn _documents ->
      {:error, :no_review_actor, %{}}
    end)

    conn = post(conn, ~p"/api/v1/reviews", %{"document_ids" => [document.id]})

    assert %{"error" => "no_review_actor"} = json_response(conn, 422)
  end

  defp expect_documents(documents) do
    by_id = Map.new(documents, &{&1.id, &1})

    expect(DocumentsMock, :get_document!, length(documents), fn id -> Map.fetch!(by_id, id) end)
  end

  defp queued_job(document_ids) do
    %Oban.Job{
      id: 42,
      worker: "RintoPMO.Annotations.ReviewWorker",
      queue: "default",
      state: "available",
      args: %{"document_ids" => document_ids},
      errors: [],
      priority: 0,
      inserted_at: ~U[2026-08-31 09:00:00.000000Z],
      scheduled_at: ~U[2026-08-31 09:00:00.000000Z]
    }
  end
end
