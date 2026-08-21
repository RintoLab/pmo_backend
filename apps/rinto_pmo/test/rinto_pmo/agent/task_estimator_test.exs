defmodule RintoPMO.Agent.TaskEstimatorTest do
  use ExUnit.Case, async: true

  alias RintoPMO.Agent.TaskEstimator

  describe "decode_items/1" do
    test "reads a JSON array of objects" do
      assert {:ok, [item]} = TaskEstimator.decode_items(~s([{"id": "abc", "difficulty": 5}]))
      assert item == %{"id" => "abc", "difficulty" => 5}
    end

    test "unwraps a markdown fence and leading prose" do
      text = """
      Here you go:

      ```json
      [{"id": "abc", "optimistic": 10, "likely": 20, "pessimistic": 40}]
      ```
      """

      assert {:ok, [item]} = TaskEstimator.decode_items(text)
      assert item["id"] == "abc"
      assert item["likely"] == 20
    end

    test "refuses a non-array, an array of non-objects, and empty text" do
      assert TaskEstimator.decode_items(~s({"id": "abc"})) == {:error, :invalid_output}
      assert TaskEstimator.decode_items("[1, 2]") == {:error, :invalid_output}
      assert TaskEstimator.decode_items("no json here") == {:error, :invalid_output}
      assert TaskEstimator.decode_items("") == {:error, :invalid_output}
    end
  end
end
