defmodule RintoPMO.Documents.ProposalPlanTest do
  use ExUnit.Case, async: true

  alias RintoPMO.Documents.BlockProposal
  alias RintoPMO.Documents.DocumentBlock
  alias RintoPMO.Documents.DocumentRevision
  alias RintoPMO.Documents.ProposalPlan

  describe "state/3" do
    test "an update is applicable while its block still says what it said" do
      base = snapshot(["One", "Two"])

      assert ProposalPlan.state(update("b0", "One, tighter"), base, base) == :applicable
    end

    test "an update whose text is already there got what it wanted" do
      base = snapshot(["One", "Two"])
      current = snapshot(["One, tighter", "Two"])

      assert ProposalPlan.state(update("b0", "One, tighter"), base, current) == :already_applied
    end

    test "an update over words that changed underneath asks a person" do
      base = snapshot(["One", "Two"])
      current = snapshot(["One, by somebody else", "Two"])

      assert ProposalPlan.state(update("b0", "One, tighter"), base, current) ==
               {:needs_confirmation, :content_diverged}
    end

    test "an update whose block has gone cannot be applied at all" do
      base = snapshot(["One", "Two"])
      current = snapshot(["Two"], ["b1"])

      assert ProposalPlan.state(update("b0", "One, tighter"), base, current) ==
               {:not_applicable, :target_deleted}
    end

    test "a change elsewhere leaves an update alone" do
      base = snapshot(["One", "Two"])
      current = snapshot(["One", "Two, edited"])

      assert ProposalPlan.state(update("b0", "One, tighter"), base, current) == :applicable
    end

    # Satisfied rather than accepted: nobody's publish did this, and recording
    # one would put a revision on it that never touched it.
    test "a deletion whose target is already gone is satisfied" do
      base = snapshot(["One", "Two"])
      current = snapshot(["Two"], ["b1"])

      assert ProposalPlan.state(delete("b0"), base, current) == :already_applied
    end

    test "a deletion over rewritten words asks a person" do
      base = snapshot(["One", "Two"])
      current = snapshot(["One, and something new", "Two"])

      assert ProposalPlan.state(delete("b0"), base, current) ==
               {:needs_confirmation, :target_rewritten}
    end

    test "an insertion needs its anchor to still be there" do
      base = snapshot(["One"])
      current = snapshot([], [])

      assert ProposalPlan.state(insert("new", "b0", "Two"), base, base) == :applicable

      assert ProposalPlan.state(insert("new", "b0", "Two"), base, current) ==
               {:not_applicable, :anchor_missing}
    end

    test "a move already in place is satisfied, and one with no anchor is not applicable" do
      base = snapshot(["One", "Two"])

      assert ProposalPlan.state(move("b0", "b1"), base, base) == :applicable
      assert ProposalPlan.state(move("b1", "b0"), base, base) == :already_applied

      assert ProposalPlan.state(move("b0", "gone"), base, base) ==
               {:not_applicable, :anchor_missing}
    end

    test "a basis that can no longer be read is a question, not a licence" do
      current = snapshot(["One"])

      assert ProposalPlan.state(update("b0", "One, tighter"), nil, current) ==
               {:needs_confirmation, :base_unreadable}
    end
  end

  describe "relevance/2" do
    # A choice is about the thing it chose between. A paragraph elsewhere
    # changing does not make it stale, and treating the whole document as the
    # subject would make every publish invalidate every pending decision.
    test "an update is about its own block and nothing else" do
      chosen = snapshot(["One", "Two"])
      elsewhere = snapshot(["One", "Two, edited"])
      here = snapshot(["One, edited", "Two"])
      proposal = update("b0", "One, tighter")

      assert ProposalPlan.relevance(proposal, chosen) ==
               ProposalPlan.relevance(proposal, elsewhere)

      refute ProposalPlan.relevance(proposal, chosen) == ProposalPlan.relevance(proposal, here)
    end

    test "a move is about where it sits, not what it says" do
      chosen = snapshot(["One", "Two"])
      reworded = snapshot(["One", "Two, edited"])
      reordered = snapshot(["Two", "One"], ["b1", "b0"])
      proposal = move("b1", nil)

      assert ProposalPlan.relevance(proposal, chosen) ==
               ProposalPlan.relevance(proposal, reworded)

      refute ProposalPlan.relevance(proposal, chosen) ==
               ProposalPlan.relevance(proposal, reordered)
    end
  end

  describe "operations/3" do
    test "reorderings run before insertions anchored on what they move" do
      current = snapshot(["One", "Two"])
      moved = move("b0", "b1")
      added = insert("new", "b1", "Three")

      assert {:ok, operations} = ProposalPlan.operations([added, moved], current, %{})
      assert Enum.map(operations, & &1.op) == [:move_after, :insert_after]
    end

    test "removals run last, so an insertion anchored on one still lands" do
      current = snapshot(["One", "Two"])

      assert {:ok, operations} =
               ProposalPlan.operations(
                 [delete("b0"), insert("new", "b0", "Between")],
                 current,
                 %{}
               )

      assert Enum.map(operations, & &1.op) == [:insert_after, :delete]
    end

    test "refuses a move whose destination the same publish removes" do
      current = snapshot(["One", "Two"])
      moved = move("b0", "b1")

      assert {:error, {:unresolved_dependency, details}} =
               ProposalPlan.operations([moved, delete("b1")], current, %{})

      assert details.proposal_ids == [moved.id]
    end

    test "refuses two moves that each want to follow the other" do
      current = snapshot(["One", "Two"])

      assert {:error, {:move_cycle, details}} =
               ProposalPlan.operations([move("b0", "b1"), move("b1", "b0")], current, %{})

      assert length(details.proposal_ids) == 2
    end

    test "a run member follows the sibling before it that is actually going to be there" do
      current = snapshot(["One"])
      run = "run-1"
      first = %{insert("i0", "b0", "Two") | run_id: run, run_ordinal: 0}
      second = %{insert("i1", "b0", "Three") | run_id: run, run_ordinal: 1}
      third = %{insert("i2", "b0", "Four") | run_id: run, run_ordinal: 2}
      siblings = %{run => [first, second, third]}

      # Taking the first and the third: the third follows the first, because the
      # second is not going to be between them.
      assert {:ok, operations} = ProposalPlan.operations([first, third], current, siblings)
      assert Enum.map(operations, & &1.after_block_id) == ["b0", "i0"]

      # Taking the second alone: nothing earlier is there, so it falls back to
      # where the run started.
      assert {:ok, [only]} = ProposalPlan.operations([second], current, siblings)
      assert only.after_block_id == "b0"
    end
  end

  defp snapshot(contents, ids \\ nil) do
    ids = ids || Enum.map(0..max(length(contents) - 1, 0), &"b#{&1}")

    blocks =
      contents
      |> Enum.zip(ids)
      |> Enum.with_index()
      |> Enum.map(fn {{content, id}, position} ->
        %DocumentBlock{block_id: id, content: content, position: position, actor_id: "a"}
      end)

    ProposalPlan.snapshot(%DocumentRevision{blocks: blocks, title: "Doc"})
  end

  defp proposal(fields) do
    struct!(
      %BlockProposal{id: "p-#{System.unique_integer([:positive])}", scope: :block, status: :live},
      fields
    )
  end

  defp update(block_id, content),
    do: proposal(operation: :update, block_id: block_id, content: content)

  defp delete(block_id), do: proposal(operation: :delete, block_id: block_id)

  defp move(block_id, after_block_id),
    do: proposal(operation: :move, block_id: block_id, after_block_id: after_block_id)

  defp insert(block_id, after_block_id, content) do
    proposal(
      operation: :insert,
      block_id: block_id,
      after_block_id: after_block_id,
      content: content
    )
  end
end
