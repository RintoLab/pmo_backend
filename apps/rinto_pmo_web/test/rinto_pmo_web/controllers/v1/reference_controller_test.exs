defmodule RintoPMOWeb.V1.ReferenceControllerTest do
  use RintoPMOWeb.ConnCase, async: true

  alias RintoPMO.References.ResolverMock

  defp resolved(fields) do
    Map.merge(
      %{
        uri: "rinto://task/x",
        type: "task",
        state: :ok,
        title: nil,
        subtitle: nil,
        excerpt: nil,
        document_id: nil,
        document_title: nil,
        archived: false
      },
      fields
    )
  end

  test "POST resolve answers one entry per URI", %{conn: conn} do
    uris = ["rinto://task/a", "rinto://intel/b"]

    expect(ResolverMock, :resolve, fn ^uris ->
      {:ok,
       [
         resolved(%{uri: "rinto://task/a", title: "接入 r-nacos", subtitle: "open"}),
         resolved(%{uri: "rinto://intel/b", type: "intel", state: :unknown_type})
       ]}
    end)

    conn = post(conn, ~p"/api/v1/references/resolve", %{uris: uris})

    assert [first, second] = json_response(conn, 200)["data"]
    assert first["uri"] == "rinto://task/a"
    assert first["state"] == "ok"
    assert first["title"] == "接入 r-nacos"
    assert second["state"] == "unknown_type"
  end

  test "POST resolve carries the document a block sits in", %{conn: conn} do
    document_id = UUIDv7.generate()

    expect(ResolverMock, :resolve, fn _uris ->
      {:ok,
       [
         resolved(%{
           uri: "rinto://block/a",
           type: "block",
           title: "部署步骤",
           document_id: document_id,
           document_title: "上线流程"
         })
       ]}
    end)

    conn = post(conn, ~p"/api/v1/references/resolve", %{uris: ["rinto://block/a"]})

    assert [data] = json_response(conn, 200)["data"]
    assert data["document_id"] == document_id
    assert data["document_title"] == "上线流程"
  end

  # Choosing `rinto://` over `/documents/{id}` was a refusal to bind stored
  # bodies to the web application's routes. Handing routes back here would put
  # that coupling in by the other door.
  test "POST resolve returns no URLs", %{conn: conn} do
    expect(ResolverMock, :resolve, fn _uris -> {:ok, [resolved(%{title: "甲"})]} end)

    conn = post(conn, ~p"/api/v1/references/resolve", %{uris: ["rinto://task/a"]})

    assert [data] = json_response(conn, 200)["data"]
    assert Map.keys(data) |> Enum.all?(&(&1 not in ["url", "path", "href", "link"]))
  end

  test "POST resolve refuses a batch over the ceiling", %{conn: conn} do
    expect(ResolverMock, :resolve, fn _uris ->
      {:error, :too_many_references, %{max: 200, given: 201}}
    end)

    conn = post(conn, ~p"/api/v1/references/resolve", %{uris: ["rinto://task/a"]})

    assert %{"error" => "too_many_references", "details" => %{"max" => 200}} =
             json_response(conn, 422)
  end

  test "POST resolve rejects a missing or malformed uris list", %{conn: conn} do
    assert %{"error" => "bad_request"} =
             conn |> post(~p"/api/v1/references/resolve", %{}) |> json_response(400)

    assert %{"error" => "bad_request"} =
             conn
             |> post(~p"/api/v1/references/resolve", %{uris: "rinto://task/a"})
             |> json_response(400)

    assert %{"error" => "bad_request"} =
             conn |> post(~p"/api/v1/references/resolve", %{uris: [1, 2]}) |> json_response(400)
  end

  test "POST resolve accepts an empty list", %{conn: conn} do
    expect(ResolverMock, :resolve, fn [] -> {:ok, []} end)

    conn = post(conn, ~p"/api/v1/references/resolve", %{uris: []})

    assert json_response(conn, 200)["data"] == []
  end
end
