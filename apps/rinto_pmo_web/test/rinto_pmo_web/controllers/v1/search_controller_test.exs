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
end
