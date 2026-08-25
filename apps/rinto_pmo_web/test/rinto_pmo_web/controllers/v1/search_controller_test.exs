defmodule RintoPMOWeb.V1.SearchControllerTest do
  use RintoPMOWeb.ConnCase, async: true

  alias RintoPMO.SearchMock

  defp result(fields) do
    Map.merge(
      %{
        uri: "rinto://block/#{UUIDv7.generate()}",
        type: "block",
        title: "部署步骤",
        excerpt: "先确认 systemd unit",
        document_id: nil,
        document_title: nil,
        score: 0.9,
        archived: false
      },
      fields
    )
  end

  test "GET search answers with addressable results", %{conn: conn} do
    document_id = UUIDv7.generate()

    expect(SearchMock, :search, fn "部署", opts ->
      assert opts[:type] == "block"
      {:ok, [result(%{document_id: document_id, document_title: "上线流程"})]}
    end)

    conn = get(conn, ~p"/api/v1/search?q=部署&type=block")

    assert [data] = json_response(conn, 200)["data"]
    assert String.starts_with?(data["uri"], "rinto://block/")
    assert data["type"] == "block"
    assert data["document_id"] == document_id
    assert data["score"] == 0.9
  end

  test "GET search passes type, scope and archived through", %{conn: conn} do
    project_id = UUIDv7.generate()

    expect(SearchMock, :search, fn "部署", opts ->
      assert opts[:type] == "document"
      assert opts[:project_id] == project_id
      assert opts[:include_archived] == true
      {:ok, []}
    end)

    conn =
      get(
        conn,
        ~p"/api/v1/search?q=部署&type=document&project_id=#{project_id}&include_archived=true"
      )

    assert json_response(conn, 200)["data"] == []
  end

  test "GET search leaves archived out unless asked", %{conn: conn} do
    expect(SearchMock, :search, fn _query, opts ->
      assert opts[:include_archived] == false
      {:ok, []}
    end)

    conn = get(conn, ~p"/api/v1/search?q=部署&type=block")

    assert json_response(conn, 200)["data"] == []
  end

  test "GET search accepts an explicit limit", %{conn: conn} do
    expect(SearchMock, :search, fn _query, opts ->
      assert opts[:limit] == 5
      {:ok, []}
    end)

    conn = get(conn, ~p"/api/v1/search?q=部署&type=block&limit=5")

    assert json_response(conn, 200)["data"] == []
  end

  test "GET search rejects a limit that is not a positive number", %{conn: conn} do
    for limit <- ["0", "-1", "abc", "5x"] do
      conn = get(conn, ~p"/api/v1/search?q=部署&type=block&limit=#{limit}")
      assert %{"error" => "bad_request"} = json_response(conn, 400)
    end
  end

  # A different question from `limit`: how deep the candidate set goes, which
  # decides what can be found at all rather than how much of it is shown.
  test "GET search accepts an explicit recall_limit", %{conn: conn} do
    expect(SearchMock, :search, fn _query, opts ->
      assert opts[:recall_limit] == 200
      assert opts[:limit] == 5
      {:ok, []}
    end)

    conn = get(conn, ~p"/api/v1/search?q=部署&type=block&limit=5&recall_limit=200")

    assert json_response(conn, 200)["data"] == []
  end

  test "GET search leaves recall_limit alone when it is not asked for", %{conn: conn} do
    expect(SearchMock, :search, fn _query, opts ->
      refute Keyword.has_key?(opts, :recall_limit)
      {:ok, []}
    end)

    conn = get(conn, ~p"/api/v1/search?q=部署&type=block")

    assert json_response(conn, 200)["data"] == []
  end

  test "GET search rejects a recall_limit that is not a positive number", %{conn: conn} do
    for recall_limit <- ["0", "-1", "abc", "5x"] do
      conn = get(conn, ~p"/api/v1/search?q=部署&type=block&recall_limit=#{recall_limit}")
      assert %{"error" => "bad_request"} = json_response(conn, 400)
    end
  end

  # Refused rather than clamped, and the ceiling comes back so a caller
  # comparing depths knows what it may ask for next.
  test "GET search says so when the depth is over the ceiling", %{conn: conn} do
    expect(SearchMock, :search, fn _query, _opts ->
      {:error, :recall_limit_too_large, %{max: 1000, given: 5000}}
    end)

    conn = get(conn, ~p"/api/v1/search?q=x&type=block&recall_limit=5000")

    assert %{"error" => "recall_limit_too_large", "details" => details} =
             json_response(conn, 422)

    assert details["max"] == 1000
    assert details["given"] == 5000
  end

  test "GET search rejects a missing query", %{conn: conn} do
    assert %{"error" => "bad_request"} =
             conn |> get(~p"/api/v1/search?type=block") |> json_response(400)
  end

  # No default: a caller that has not said what it is looking for has not
  # decided, and picking for it would search one kind of thing while the caller
  # believed it was searching everything.
  test "GET search rejects a missing type", %{conn: conn} do
    assert %{"error" => "bad_request", "details" => %{"type" => _}} =
             conn |> get(~p"/api/v1/search?q=部署") |> json_response(400)
  end

  # Said rather than answered with an empty list: the question could never have
  # found anything, which is a mistake in the request rather than a result.
  test "GET search says so when nothing of that kind is indexed", %{conn: conn} do
    expect(SearchMock, :search, fn _query, _opts ->
      {:error, :unsearchable_type, %{type: "proposal", searchable: ["block", "task"]}}
    end)

    conn = get(conn, ~p"/api/v1/search?q=x&type=proposal")

    assert %{"error" => "unsearchable_type", "details" => details} = json_response(conn, 422)
    assert details["type"] == "proposal"
  end

  # An installation deployed without RINTO_AI_TOKEN answers every search this
  # way, and the message is what tells whoever deployed it what is missing.
  test "GET search says so when this server has no inference credential", %{conn: conn} do
    expect(SearchMock, :search, fn _query, _opts -> {:error, :ai_not_configured, %{}} end)

    conn = get(conn, ~p"/api/v1/search?q=部署&type=block")

    assert %{"error" => "ai_not_configured", "message" => message} = json_response(conn, 503)
    assert message =~ "RINTO_AI_TOKEN"
  end

  test "GET search says so when the inference service is down", %{conn: conn} do
    expect(SearchMock, :search, fn _query, _opts ->
      {:error, :ai_unavailable, %{reason: ":econnrefused"}}
    end)

    conn = get(conn, ~p"/api/v1/search?q=部署&type=block")

    assert %{"error" => "ai_unavailable", "details" => details} = json_response(conn, 503)
    assert details["reason"] == ":econnrefused"
  end
end
