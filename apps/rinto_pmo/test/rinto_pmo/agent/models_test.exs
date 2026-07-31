defmodule RintoPMO.Agent.ModelsTest do
  use ExUnit.Case, async: true

  alias RintoPMO.Agent.AIModel
  alias RintoPMO.Agent.Models

  describe "header contract" do
    test "documents the stable pi --list-models header columns" do
      assert Models.header_columns() == [
               "provider",
               "model",
               "context",
               "max-out",
               "thinking",
               "images"
             ]
    end

    test "accepts output whose first table row is the fixed header" do
      output = """
      provider  model  context  max-out  thinking  images
      acme      m1     1000     500      no        no
      """

      assert {:ok, [%AIModel{} = model]} = Models.parse_output(output)
      assert model.provider == "acme"
      assert model.model == "m1"
    end

    test "rejects output without the fixed header row" do
      assert {:error, :unrecognized_output} =
               Models.parse_output("acme  m1  1000  500  no  no")
    end
  end

  describe "parse_output/1" do
    test "returns AIModel structs" do
      output = """
      provider  model              context  max-out  thinking  images
      deepseek  deepseek-v4-flash  1M       384K     yes       no
      """

      assert {:ok, [%AIModel{} = model]} = Models.parse_output(output)
      assert model.provider == "deepseek"
      assert model.model == "deepseek-v4-flash"
      assert model.context_window == 1_000_000
      assert model.max_output == 384_000
      assert model.thinking == true
      assert model.images == false
    end

    test "returns an empty list when no models are available" do
      assert {:ok, []} =
               Models.parse_output("No models available. Run /login or set provider API keys.")
    end
  end

  describe "list_models/1" do
    @tag :pi_cli
    test "runs pi and only asserts the fixed header contract via a successful parse" do
      case System.find_executable("pi") do
        nil ->
          flunk("pi executable not found on PATH")

        _path ->
          assert {:ok, models} = Models.list_models()
          assert is_list(models)
          assert Enum.all?(models, &match?(%AIModel{}, &1))
      end
    end

    test "returns pi_not_found for a missing executable" do
      assert {:error, :pi_not_found} =
               Models.list_models(
                 executable: "pi-binary-that-does-not-exist-#{System.unique_integer()}"
               )
    end
  end
end
