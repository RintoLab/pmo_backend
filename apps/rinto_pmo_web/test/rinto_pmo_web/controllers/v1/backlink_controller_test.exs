defmodule RintoPMOWeb.V1.BacklinkControllerTest do
  use RintoPMOWeb.ConnCase, async: true

  alias RintoPMO.LinksMock
  alias RintoPMO.References.Reference

  defp backlink(fields) do
    Map.merge(
      %{
        source_type: "document_block",
        source_id: UUIDv7.generate(),
        document_id: nil,
        document_title: nil,
        title: nil,
        excerpt: nil,
        label: "标签",
        position: 0,
        archived: false
      },
      fields
    )
  end

  test "GET backlinks groups by the kind of source", %{conn: conn} do
    task_id = UUIDv7.generate()

    expect(LinksMock, :backlinks, fn %Reference{type: "task", key: ^task_id} ->
      [
        backlink(%{source_type: "document_block", document_title: "上线流程", label: "接入"}),
        backlink(%{source_type: "task", title: "甲", label: "依赖"}),
        backlink(%{source_type: "document_block", document_title: "另一篇", label: "又见"})
      ]
    end)

    conn = get(conn, ~p"/api/v1/backlinks?target=rinto://task/#{task_id}")

    assert %{"total" => 3, "groups" => groups} = json_response(conn, 200)["data"]
    assert [blocks, tasks] = groups
    assert blocks["source_type"] == "document_block"
    assert blocks["count"] == 2
    assert tasks["source_type"] == "task"
    assert [%{"label" => "接入"}, %{"label" => "又见"}] = blocks["entries"]
  end

  test "GET backlinks answers nothing as an empty result", %{conn: conn} do
    expect(LinksMock, :backlinks, fn _reference -> [] end)

    conn = get(conn, ~p"/api/v1/backlinks?target=rinto://task/#{UUIDv7.generate()}")

    assert %{"total" => 0, "groups" => []} = json_response(conn, 200)["data"]
  end

  test "GET backlinks keeps the broken-target case answerable", %{conn: conn} do
    expect(LinksMock, :backlinks, fn _reference ->
      [backlink(%{source_type: "task", title: "甲", label: "没了的"})]
    end)

    conn = get(conn, ~p"/api/v1/backlinks?target=rinto://task/#{UUIDv7.generate()}")

    assert [%{"entries" => [%{"label" => "没了的"}]}] = json_response(conn, 200)["data"]["groups"]
  end

  test "GET backlinks rejects a target that is not a rinto URI", %{conn: conn} do
    for target <- ["https://example.test", "rinto://task/not-a-uuid", "rinto://block:abc"] do
      conn = get(conn, ~p"/api/v1/backlinks?target=#{target}")
      assert %{"error" => "validation_error"} = json_response(conn, 422)
    end
  end

  test "GET backlinks rejects a missing target", %{conn: conn} do
    assert %{"error" => "bad_request"} =
             conn |> get(~p"/api/v1/backlinks") |> json_response(400)
  end

  # An unknown type is not an error anywhere else, and it is not one here.
  test "GET backlinks accepts an unknown type and answers nothing", %{conn: conn} do
    expect(LinksMock, :backlinks, fn %Reference{type: "intel"} -> [] end)

    conn = get(conn, ~p"/api/v1/backlinks?target=rinto://intel/whatever")

    assert %{"total" => 0} = json_response(conn, 200)["data"]
  end
end
