defmodule RintoPMOWeb.V1.AIModelControllerTest do
  use RintoPMOWeb.ConnCase, async: false

  alias RintoPMO.Agent.AIModel
  alias RintoPMO.Agent.ModelCatalog

  setup do
    :ok =
      ModelCatalog.replace!([
        AIModel.new!(%{
          provider: "acme",
          model: "alpha",
          context_window: 10_000,
          max_output: 1_000,
          thinking: false,
          images: false
        }),
        AIModel.new!(%{
          provider: "openai",
          model: "gpt-test",
          context_window: 100_000,
          max_output: 8_000,
          thinking: true,
          images: true
        })
      ])

    :ok
  end

  test "GET /api/v1/ai_models lists providers and models for actor creation", %{conn: conn} do
    conn = get(conn, ~p"/api/v1/ai_models")

    assert %{
             "data" => [
               %{
                 "provider" => "acme",
                 "models" => [
                   %{
                     "model" => "alpha",
                     "context_window" => 10_000,
                     "max_output" => 1_000,
                     "thinking" => false,
                     "images" => false
                   }
                 ]
               },
               %{
                 "provider" => "openai",
                 "models" => [
                   %{
                     "model" => "gpt-test",
                     "context_window" => 100_000,
                     "max_output" => 8_000,
                     "thinking" => true,
                     "images" => true
                   }
                 ]
               }
             ]
           } = json_response(conn, 200)
  end
end
