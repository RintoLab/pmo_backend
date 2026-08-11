defmodule RintoPMO.Documents.BlockMergeTest do
  use ExUnit.Case, async: true

  alias RintoPMO.Documents.BlockMerge

  describe "merge/3" do
    test "takes the proposal's text where only the proposal changed a block" do
      base = blocks(a: "One", b: "Two")
      theirs = blocks(a: "One, tighter", b: "Two")
      ours = blocks(a: "One", b: "Two")

      assert {:ok, ["One, tighter", "Two"]} = BlockMerge.merge(base, theirs, ours)
    end

    # The proposal has no opinion about this block, so the edit that landed
    # under it survives untouched.
    test "takes the landed text where only the other side changed a block" do
      base = blocks(a: "One", b: "Two")
      theirs = blocks(a: "One", b: "Two, tighter")
      ours = blocks(a: "One, theirs", b: "Two")

      assert {:ok, ["One, theirs", "Two, tighter"]} = BlockMerge.merge(base, theirs, ours)
    end

    test "keeps both edits when they are on different blocks" do
      base = blocks(a: "One", b: "Two", c: "Three")
      theirs = blocks(a: "One", b: "Two", c: "Three, mine")
      ours = blocks(a: "One, theirs", b: "Two", c: "Three")

      assert {:ok, ["One, theirs", "Two", "Three, mine"]} = BlockMerge.merge(base, theirs, ours)
    end

    test "agrees when both sides made the same change" do
      base = blocks(a: "One")
      theirs = blocks(a: "One, tighter")
      ours = blocks(a: "One, tighter")

      assert {:ok, ["One, tighter"]} = BlockMerge.merge(base, theirs, ours)
    end

    # Choosing between two people's words is the one thing this never does on
    # its own.
    test "conflicts when both sides changed one block differently" do
      base = blocks(a: "One", b: "Two")
      theirs = blocks(a: "One, mine", b: "Two")
      ours = blocks(a: "One, theirs", b: "Two")

      assert {:conflict, %{reason: :diverged, block_ids: [:a]}} =
               BlockMerge.merge(base, theirs, ours)
    end

    test "keeps a block the proposal added" do
      base = blocks(a: "One")
      theirs = blocks(a: "One", new: "Two")
      ours = blocks(a: "One")

      assert {:ok, ["One", "Two"]} = BlockMerge.merge(base, theirs, ours)
    end

    test "carries an insertion across an edit that landed elsewhere" do
      base = blocks(a: "One", b: "Two")
      theirs = blocks(a: "One", new: "One and a half", b: "Two")
      ours = blocks(a: "One", b: "Two, theirs")

      assert {:ok, ["One", "One and a half", "Two, theirs"]} =
               BlockMerge.merge(base, theirs, ours)
    end

    test "drops a block the proposal removed and nobody else touched" do
      base = blocks(a: "One", b: "Two")
      theirs = blocks(a: "One")
      ours = blocks(a: "One", b: "Two")

      assert {:ok, ["One"]} = BlockMerge.merge(base, theirs, ours)
    end

    # Removing it now would throw that edit away without anybody seeing it.
    test "conflicts when the proposal removed a block the other side had edited" do
      base = blocks(a: "One", b: "Two")
      theirs = blocks(a: "One")
      ours = blocks(a: "One", b: "Two, theirs")

      assert {:conflict, %{reason: :diverged, block_ids: [:b]}} =
               BlockMerge.merge(base, theirs, ours)
    end

    test "reports every conflicting block, not just the first" do
      base = blocks(a: "One", b: "Two")
      theirs = blocks(a: "One, mine", b: "Two, mine")
      ours = blocks(a: "One, theirs", b: "Two, theirs")

      assert {:conflict, %{block_ids: block_ids}} = BlockMerge.merge(base, theirs, ours)
      assert Enum.sort(block_ids) == [:a, :b]
    end

    test "refuses a rebase when a block arrived underneath" do
      base = blocks(a: "One")
      theirs = blocks(a: "One, mine")
      ours = blocks(a: "One", arrived: "Two")

      assert {:conflict, %{reason: :restructured, added: [:arrived], removed: []}} =
               BlockMerge.merge(base, theirs, ours)
    end

    test "refuses a rebase when a block went away underneath" do
      base = blocks(a: "One", b: "Two")
      theirs = blocks(a: "One, mine", b: "Two")
      ours = blocks(a: "One")

      assert {:conflict, %{reason: :restructured, removed: [:b]}} =
               BlockMerge.merge(base, theirs, ours)
    end

    # Compared as a list, not a set, so a pure reorder is caught too.
    test "refuses a rebase when the blocks were reordered underneath" do
      base = blocks(a: "One", b: "Two")
      theirs = blocks(a: "One, mine", b: "Two")
      ours = [%{block_id: :b, content: "Two"}, %{block_id: :a, content: "One"}]

      assert {:conflict, %{reason: :restructured}} = BlockMerge.merge(base, theirs, ours)
    end

    test "a proposal that changed nothing merges to what now stands" do
      base = blocks(a: "One", b: "Two")
      theirs = blocks(a: "One", b: "Two")
      ours = blocks(a: "One, theirs", b: "Two")

      assert {:ok, ["One, theirs", "Two"]} = BlockMerge.merge(base, theirs, ours)
    end

    test "an empty document on every side merges to nothing" do
      assert {:ok, []} = BlockMerge.merge([], [], [])
    end
  end

  defp blocks(entries) do
    for {block_id, content} <- entries, do: %{block_id: block_id, content: content}
  end
end
