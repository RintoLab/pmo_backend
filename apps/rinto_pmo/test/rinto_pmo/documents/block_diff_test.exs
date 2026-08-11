defmodule RintoPMO.Documents.BlockDiffTest do
  use ExUnit.Case, async: true

  alias RintoPMO.Documents.BlockDiff
  alias RintoPMO.Documents.BlockOps
  alias RintoPMO.Documents.DocumentBlock

  doctest BlockDiff

  describe "compile/3" do
    test "produces nothing when the sequence is unchanged" do
      assert BlockDiff.compile(blocks(["One", "Two"]), ["One", "Two"], "actor") == []
    end

    test "an edited block keeps its id" do
      parent = blocks(["One", "Two"])

      assert [%{op: :update} = operation] =
               BlockDiff.compile(parent, ["One", "Two, tighter"], "actor")

      assert operation.block_id == "b1"
      assert operation.content == "Two, tighter"
      assert operation.actor_id == "actor"
    end

    test "appending hangs off the last block" do
      assert [%{op: :insert_after} = operation] =
               BlockDiff.compile(blocks(["One"]), ["One", "Two"], "actor")

      assert operation.after_block_id == "b0"
      assert operation.content == "Two"
    end

    # `BlockOps` reads a nil anchor as the head of the document, which is the
    # only thing a block inserted before every existing block can follow.
    test "inserting at the head anchors on nothing" do
      assert [%{op: :insert_after, after_block_id: nil, content: "Zero"}] =
               BlockDiff.compile(blocks(["One"]), ["Zero", "One"], "actor")
    end

    test "a removed block is deleted" do
      assert [%{op: :delete, block_id: "b1"}] =
               BlockDiff.compile(blocks(["One", "Two"]), ["One"], "actor")
    end

    # The case a block proposal could never express: one paragraph becomes two.
    # The first keeps the original id, so an annotation on it survives.
    test "splitting a block updates it and inserts the remainder" do
      parent = blocks(["Intro", "Body"])

      assert [update, insert] = BlockDiff.compile(parent, ["Intro", "Body one", "Body two"], "a")

      assert update == %{op: :update, block_id: "b1", actor_id: "a", content: "Body one"}
      assert insert.op == :insert_after
      assert insert.after_block_id == "b1"
      assert insert.content == "Body two"
    end

    test "merging two blocks updates the first and deletes the second" do
      parent = blocks(["Intro", "One", "Two"])

      assert [update, delete] = BlockDiff.compile(parent, ["Intro", "One and two"], "a")

      assert update == %{op: :update, block_id: "b1", actor_id: "a", content: "One and two"}
      assert delete == %{op: :delete, block_id: "b2"}
    end

    # Their own ids are generated inside BlockOps, so none of them can anchor
    # the next -- they share one anchor and are emitted back to front.
    test "consecutive insertions share an anchor and still land in order" do
      parent = blocks(["One"])

      operations = BlockDiff.compile(parent, ["One", "Two", "Three", "Four"], "a")

      assert Enum.map(operations, & &1.content) == ["Four", "Three", "Two"]
      assert Enum.all?(operations, &(&1.after_block_id == "b0"))
      assert {:ok, entries} = BlockOps.apply(parent, operations)
      assert Enum.map(entries, & &1.content) == ["One", "Two", "Three", "Four"]
    end

    # One gap losing blocks and another gaining them, so all three kinds appear
    # at once and their relative order is visible.
    test "content changes are ordered ahead of removals and additions" do
      parent = blocks(["Keep", "Cut one", "Cut two", "Anchor", "Edit"])

      operations = BlockDiff.compile(parent, ["Keep", "Anchor", "Edited", "New"], "a")

      assert Enum.map(operations, & &1.op) == [:update, :delete, :delete, :insert_after]
      assert {:ok, entries} = BlockOps.apply(parent, operations)
      assert Enum.map(entries, & &1.content) == ["Keep", "Anchor", "Edited", "New"]
    end

    # Pairing consumes as much as it can, so a run of changed blocks becomes a
    # run of updates rather than a pile of deletes and inserts. Every id in the
    # run survives, which is the whole point of pairing positionally.
    test "a run of rewritten blocks becomes updates, not replacements" do
      parent = blocks(["One", "Two", "Three"])

      operations = BlockDiff.compile(parent, ["One, tighter", "Four"], "a")

      assert Enum.map(operations, & &1.op) == [:update, :update, :delete]
      assert {:ok, entries} = BlockOps.apply(parent, operations)
      assert Enum.map(entries, & &1.block_id) == ["b0", "b1"]
    end

    # A reorder is a delete and an insert: telling a move from a coincidence
    # needs a similarity measure, and guessing wrong rewrites the wrong
    # paragraph's history. The id is the documented cost.
    test "a moved block does not keep its id" do
      parent = blocks(["One", "Two"])

      operations = BlockDiff.compile(parent, ["Two", "One"], "a")

      assert {:ok, entries} = BlockOps.apply(parent, operations)
      assert Enum.map(entries, & &1.content) == ["Two", "One"]
      assert Enum.map(entries, & &1.block_id) != ["b1", "b0"]
    end

    test "every untouched block keeps its id through an edit in the middle" do
      parent = blocks(["One", "Two", "Three"])

      operations = BlockDiff.compile(parent, ["One", "Two, tighter", "Three"], "a")

      assert {:ok, entries} = BlockOps.apply(parent, operations)
      assert Enum.map(entries, & &1.block_id) == ["b0", "b1", "b2"]
    end

    test "an empty document can be filled and a full one emptied" do
      assert {:ok, filled} = BlockOps.apply([], BlockDiff.compile([], ["One", "Two"], "a"))
      assert Enum.map(filled, & &1.content) == ["One", "Two"]

      parent = blocks(["One", "Two"])
      assert {:ok, []} = BlockOps.apply(parent, BlockDiff.compile(parent, [], "a"))
    end
  end

  # The operations are only correct if applying them produces the sequence that
  # was asked for, and the ways they can fail -- an anchor deleted before its
  # insert, insertions in the wrong order, a gap paired off by one -- all show up
  # as the wrong final list. So rather than trust the cases above to have found
  # them, every small rearrangement is applied and checked.
  describe "compile/3 round trip" do
    @sources [[], ["A"], ["A", "B"], ["A", "B", "C"], ["A", "C"], ["B", "A"]]

    test "applying the operations always yields the requested sequence" do
      for source <- @sources, target <- targets() do
        parent = blocks(source)
        operations = BlockDiff.compile(parent, target, "actor")

        assert {:ok, entries} = BlockOps.apply(parent, operations),
               "#{inspect(source)} -> #{inspect(target)} produced #{inspect(operations)}"

        assert Enum.map(entries, & &1.content) == target,
               "#{inspect(source)} -> #{inspect(target)} produced #{inspect(operations)}"

        # Whatever the shape, ids stay unique -- an insert that reused an anchor's
        # id would corrupt every later operation naming it.
        ids = Enum.map(entries, & &1.block_id)
        assert Enum.uniq(ids) == ids
      end
    end

    test "a block whose content survives keeps its id, whatever moved around it" do
      for source <- @sources, target <- targets() do
        parent = blocks(source)
        operations = BlockDiff.compile(parent, target, "actor")
        assert {:ok, entries} = BlockOps.apply(parent, operations)

        kept = Enum.filter(entries, &(&1.block_id in Enum.map(parent, fn b -> b.block_id end)))

        for entry <- kept, original = Enum.find(parent, &(&1.block_id == entry.block_id)) do
          # It kept its id, so it is the same block: either untouched, or updated
          # in place. Either way it must still be in the target.
          assert entry.content in target,
                 "#{inspect(source)} -> #{inspect(target)}: #{original.block_id} kept its id " <>
                   "but holds #{inspect(entry.content)}"
        end
      end
    end
  end

  # Every list of length 0..3 over an alphabet that overlaps the sources
  # partially, so matches, insertions and deletions all occur.
  defp targets do
    alphabet = ["A", "B", "D"]

    for length <- 0..3, combination <- lists_of(alphabet, length), do: combination
  end

  defp lists_of(_alphabet, 0), do: [[]]

  defp lists_of(alphabet, length) do
    for head <- alphabet, tail <- lists_of(alphabet, length - 1), do: [head | tail]
  end

  defp blocks(contents) do
    contents
    |> Enum.with_index()
    |> Enum.map(fn {content, index} ->
      %DocumentBlock{block_id: "b#{index}", actor_id: "author", content: content}
    end)
  end
end
