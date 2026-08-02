defmodule RintoPMO.Agent.ModelsTest do
  use ExUnit.Case, async: true

  import Hammox

  alias RintoPMO.Agent.AIModel
  alias RintoPMO.Agent.Models

  describe "from_rpc_response/1" do
    test "maps get_available_models payloads into AIModel structs with thinking levels" do
      response = %{
        "type" => "response",
        "command" => "get_available_models",
        "success" => true,
        "data" => %{
          "models" => [
            %{
              "provider" => "deepseek",
              "id" => "deepseek-v4-pro",
              "name" => "DeepSeek V4 Pro",
              "reasoning" => true,
              "contextWindow" => 1_000_000,
              "maxTokens" => 384_000,
              "input" => ["text"],
              "thinkingLevelMap" => %{
                "minimal" => nil,
                "low" => nil,
                "medium" => nil,
                "high" => "high",
                "max" => "max"
              }
            },
            %{
              "provider" => "acme",
              "id" => "vision",
              "reasoning" => false,
              "contextWindow" => 100_000,
              "maxTokens" => 8_000,
              "input" => ["text", "image"]
            }
          ]
        }
      }

      assert {:ok, models} = Models.from_rpc_response(response)

      assert [
               %AIModel{
                 provider: "acme",
                 model: "vision",
                 thinking: false,
                 thinking_levels: [:off],
                 images: true
               },
               %AIModel{
                 provider: "deepseek",
                 model: "deepseek-v4-pro",
                 name: "DeepSeek V4 Pro",
                 thinking: true,
                 thinking_levels: [:off, :high, :max],
                 images: false,
                 context_window: 1_000_000,
                 max_output: 384_000
               }
             ] = models
    end

    test "returns rpc errors from unsuccessful responses" do
      assert {:error, {:rpc_error, "boom"}} =
               Models.from_rpc_response(%{"success" => false, "error" => "boom"})
    end

    test "rejects unrecognized payloads" do
      assert {:error, :unrecognized_output} = Models.from_rpc_response(%{"success" => true})
    end
  end

  describe "AIModel.thinking_levels_for/1" do
    test "requires explicit map entries for xhigh and max" do
      model = %{
        "reasoning" => true,
        "thinkingLevelMap" => %{
          "high" => "high",
          "xhigh" => "xhigh"
        }
      }

      assert AIModel.thinking_levels_for(model) == [
               :off,
               :minimal,
               :low,
               :medium,
               :high,
               :xhigh
             ]
    end
  end

  # Rpc is mocked: this module's job is to ask for `get_available_models` and
  # turn the answer into structs. Whether an RPC round trip actually works is
  # RpcTest's concern, and needs no pi installed here.
  describe "list_models/1" do
    setup :verify_on_exit!

    test "asks pi for the model catalog and maps the answer" do
      expect(RintoPMO.Agent.RpcMock, :request, fn command, _opts ->
        assert command == %{"type" => "get_available_models"}

        {:ok,
         %{
           "success" => true,
           "data" => %{
             "models" => [
               %{
                 "provider" => "acme",
                 "id" => "alpha",
                 "name" => "Alpha",
                 "contextWindow" => 1000,
                 "maxTokens" => 100,
                 "input" => ["text", "image"],
                 "reasoning" => true,
                 # "medium" is absent rather than null, so it counts as supported.
                 "thinkingLevelMap" => %{"minimal" => nil, "low" => "low", "high" => "high"}
               }
             ]
           }
         }}
      end)

      assert {:ok,
              [
                %AIModel{
                  provider: "acme",
                  model: "alpha",
                  name: "Alpha",
                  thinking: true,
                  thinking_levels: [:off, :low, :medium, :high],
                  images: true
                }
              ]} = Models.list_models()
    end

    test "passes caller options through to the RPC layer" do
      expect(RintoPMO.Agent.RpcMock, :request, fn _command, opts ->
        assert Keyword.fetch!(opts, :timeout) == 1234
        assert Keyword.fetch!(opts, :offline) == true

        {:ok, %{"success" => true, "data" => %{"models" => []}}}
      end)

      assert {:ok, []} = Models.list_models(timeout: 1234, offline: true)
    end

    test "surfaces an RPC failure unchanged" do
      expect(RintoPMO.Agent.RpcMock, :request, fn _command, _opts -> {:error, :pi_not_found} end)

      assert {:error, :pi_not_found} = Models.list_models()
    end

    test "reports a payload it cannot make sense of" do
      expect(RintoPMO.Agent.RpcMock, :request, fn _command, _opts ->
        {:ok, %{"success" => true, "data" => %{"models" => [%{"provider" => "acme"}]}}}
      end)

      assert {:error, :unrecognized_output} = Models.list_models()
    end
  end
end
