defmodule RintoPMO.Documents.BlockOpsTest do
  use ExUnit.Case, async: true

  alias RintoPMO.Documents.BlockOps
  alias RintoPMO.Documents.DocumentBlock

  test "applies insert, update, move, and delete operations in order" do
    actor_id = UUIDv7.generate()
    next_actor_id = UUIDv7.generate()
    first_id = UUIDv7.generate()
    second_id = UUIDv7.generate()

    blocks = [
      block(first_id, actor_id, "First"),
      block(second_id, actor_id, "Second")
    ]

    operations = [
      %{op: :update, block_id: second_id, actor_id: next_actor_id, content: "Updated"},
      %{op: :move_after, block_id: second_id, after_block_id: nil},
      %{op: :delete, block_id: first_id},
      %{op: :insert_after, after_block_id: second_id, actor_id: actor_id, content: "New"}
    ]

    assert {:ok, [updated, inserted]} = BlockOps.apply(blocks, operations)
    assert updated == %{block_id: second_id, actor_id: next_actor_id, content: "Updated"}
    assert inserted.actor_id == actor_id
    assert inserted.content == "New"
    assert inserted.block_id not in [first_id, second_id]
  end

  test "returns the failing operation index for invalid references" do
    block_id = UUIDv7.generate()

    assert {:error, :invalid_block_op,
            %{operation_index: 0, reason: "block_id does not identify a current block"}} =
             BlockOps.apply([], [%{op: :delete, block_id: block_id}])
  end

  test "rejects unsupported operations" do
    assert {:error, :invalid_block_op,
            %{operation_index: 0, reason: "unsupported operation: \"merge\""}} =
             BlockOps.apply([], [%{"op" => "merge"}])
  end

  defp block(block_id, actor_id, content) do
    %DocumentBlock{block_id: block_id, actor_id: actor_id, content: content}
  end
end
