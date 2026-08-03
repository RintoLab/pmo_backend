defmodule RintoPMOWeb.V1.AIModelControllerTest do
  use RintoPMOWeb.ConnCase, async: false

  @moduletag :capture_log

  alias RintoPMO.Agent.AIModel
  alias RintoPMO.Agent.ModelCatalog

  setup do
    :ok =
      ModelCatalog.replace!([
        AIModel.new!(%{
          provider: "acme",
          model: "alpha",
          name: "Alpha",
          context_window: 10_000,
          max_output: 1_000,
          thinking: false,
          thinking_levels: [:off],
          images: false
        }),
        AIModel.new!(%{
          provider: "openai",
          model: "gpt-test",
          context_window: 100_000,
          max_output: 8_000,
          thinking: true,
          thinking_levels: [:off, :low, :high],
          images: true
        })
      ])

    :ok
  end

  test "GET /api/v1/ai_models lists providers, models, and thinking levels", %{conn: conn} do
    conn = get(conn, ~p"/api/v1/ai_models")

    assert %{
             "data" => [
               %{
                 "provider" => "acme",
                 "models" => [
                   %{
                     "model" => "alpha",
                     "name" => "Alpha",
                     "context_window" => 10_000,
                     "max_output" => 1_000,
                     "thinking" => false,
                     "thinking_levels" => ["off"],
                     "images" => false
                   }
                 ]
               },
               %{
                 "provider" => "openai",
                 "models" => [
                   %{
                     "model" => "gpt-test",
                     "thinking" => true,
                     "thinking_levels" => ["off", "low", "high"],
                     "images" => true
                   }
                 ]
               }
             ]
           } = json_response(conn, 200)
  end

  test "GET /api/v1/ai_models reports catalog status alongside the models", %{conn: conn} do
    conn = get(conn, ~p"/api/v1/ai_models")

    assert %{
             "status" => %{
               "state" => "ok",
               "loading" => false,
               "updated_at" => updated_at,
               "error" => nil
             }
           } = json_response(conn, 200)

    assert {:ok, %DateTime{}, _offset} = DateTime.from_iso8601(updated_at)
  end

  test "GET /api/v1/ai_models distinguishes an empty catalog from a failed one", %{conn: conn} do
    # An empty `data` alone cannot say whether discovery worked, which is the
    # whole reason `status` is in the response.
    :ok = ModelCatalog.replace!([])

    assert %{"data" => [], "status" => %{"state" => "ok"}} =
             conn |> get(~p"/api/v1/ai_models") |> json_response(200)
  end

  describe "POST /api/v1/ai_models/refresh" do
    test "answers without waiting for discovery", %{conn: conn} do
      expect(RintoPMO.Agent.RpcMock, :request, fn %{"type" => "get_available_models"}, [] ->
        {:ok, %{"success" => true, "data" => %{"models" => []}}}
      end)

      # Discovery runs under the catalog's task rather than the test process,
      # so explicitly give it access to this test's mock expectation.
      allow(RintoPMO.Agent.RpcMock, self(), ModelCatalog)

      assert conn |> post(~p"/api/v1/ai_models/refresh") |> response(204) == ""
      assert :ok = await_idle()
    end
  end

  # A refresh is a cast, so it is not necessarily under way when this is called.
  # Syncing on the process first makes sure this waits for the run just asked
  # for rather than observing the idle state preceding it.
  defp await_idle do
    :sys.get_state(ModelCatalog)

    Enum.reduce_while(1..300, :timeout, fn _i, _acc ->
      if Map.fetch!(ModelCatalog.status(), :loading?) do
        Process.sleep(20)
        {:cont, :timeout}
      else
        {:halt, :ok}
      end
    end)
  end
end
