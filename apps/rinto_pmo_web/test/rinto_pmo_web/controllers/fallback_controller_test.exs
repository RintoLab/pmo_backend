defmodule RintoPMOWeb.FallbackControllerTest do
  use RintoPMOWeb.ConnCase, async: true

  alias RintoPMOWeb.FallbackController

  test "renders tagged domain errors with their configured status and details", %{conn: conn} do
    details = %{
      base_version: 2,
      current_version: 3,
      diff: [%{op: "replace", block_id: "block-1"}]
    }

    conn =
      conn
      |> Phoenix.Controller.put_format("json")
      |> FallbackController.call({:error, :stale_document, details})

    assert json_response(conn, 409) == %{
             "error" => "stale_document",
             "message" => "The document has changed since the provided base revision.",
             "details" => %{
               "base_version" => 2,
               "current_version" => 3,
               "diff" => [%{"op" => "replace", "block_id" => "block-1"}]
             }
           }
  end
end
