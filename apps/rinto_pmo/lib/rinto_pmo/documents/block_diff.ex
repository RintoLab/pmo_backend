defmodule RintoPMO.Documents.BlockDiff do
  @moduledoc """
  Turns a rewritten block sequence into the operations that produce it.

  A `:document` proposal carries whole-document Markdown. What the revision layer
  accepts is a list of `RintoPMO.Documents.BlockOps` operations against the
  parent's blocks, so something has to work out which blocks survived, which were
  edited, and which came or went. That is this.

  ## Why not simply replace every block

  Because `block_id` is the thread everything else hangs from: an annotation is
  anchored to one, another topic's live proposal names one, and history reads
  through them. Replacing the sequence wholesale would issue new ids for blocks
  nobody touched, orphaning all of it at once.

  So blocks are matched first, and only what genuinely changed gives up its id:

    * identical content, in the same relative order -- kept, no operation at all
    * changed content in a stable position -- `update`, **id preserved**, so an
      annotation on an edited paragraph still points at it
    * genuinely new -- `insert_after`
    * genuinely gone -- `delete`

  ## What it does not do

  A block that moved is expressed as a delete and an insert, so it comes back
  with a new id. `move_after` exists in `BlockOps` and would preserve it, but
  telling a move from a coincidence needs a similarity measure rather than the
  equality this uses, and guessing wrong silently rewrites the wrong paragraph's
  history. Reordering is rarer than editing; this is the documented cost.

  ## Matching

  The longest common subsequence of the two content lists gives the anchors --
  the blocks that are unarguably the same block, in an order both versions agree
  on. Everything between two anchors is then a gap holding some old blocks and
  some new contents, and those are paired off positionally: the first old block
  in the gap becomes the first new content, and so on. Pairs are `update`s;
  whichever list runs out first leaves `insert_after`s or `delete`s behind.

  Positional pairing inside a gap is a guess, but a contained one -- it can only
  ever mismatch blocks that are already adjacent and already changed, and the
  cost of being wrong is a `block_id` on the wrong paragraph rather than lost
  text.
  """

  alias RintoPMO.Documents.DocumentBlock

  @type operation :: %{required(:op) => atom(), optional(atom()) => term()}

  @doc """
  Compiles the operations that turn `blocks` into `contents`.

  `blocks` is the parent revision's ordered block snapshot; `contents` is the
  new block bodies, in order, as `RintoPMO.Documents.Markdown.split/1` returns
  them. `actor_id` is credited with every block the operations write.

  The result is ordered so that it applies cleanly in sequence: content changes
  first, then removals, then additions. Every anchor an addition names is a
  block that survives the whole list, so no operation can be undone by a later
  one.

      iex> alias RintoPMO.Documents.{BlockDiff, DocumentBlock}
      iex> blocks = [%DocumentBlock{block_id: "a", content: "One"}]
      iex> BlockDiff.compile(blocks, ["One", "Two"], "actor")
      [%{op: :insert_after, after_block_id: "a", actor_id: "actor", content: "Two"}]
  """
  @spec compile([DocumentBlock.t()], [String.t()], UUIDv7.t()) :: [operation()]
  def compile(blocks, contents, actor_id) when is_list(blocks) and is_list(contents) do
    old = Enum.map(blocks, &{&1.block_id, &1.content})

    old
    |> segments(contents)
    |> Enum.flat_map(&reconcile(&1, actor_id))
    |> order()
  end

  # Cuts both sequences at the anchors into `{old_gap, new_gap, preceding}` runs,
  # where `preceding` is the kept block immediately *before* the gap -- `nil` for
  # the leading one, which has nothing before it. Additions need the block they
  # follow, not the one they precede.
  #
  # The indexes a match carries are relative to the unconsumed tail rather than
  # to the original list, which is what lets each gap come off with a plain
  # `Enum.split/2` instead of arithmetic.
  defp segments(old, contents) do
    matches = lcs(Enum.map(old, &elem(&1, 1)), contents)

    {segments, old_rest, new_rest, preceding} =
      Enum.reduce(matches, {[], old, contents, nil}, fn {old_index, new_index},
                                                        {segments, old_rest, new_rest, preceding} ->
        {old_gap, [{anchor, _content} | old_tail]} = Enum.split(old_rest, old_index)
        {new_gap, [_kept | new_tail]} = Enum.split(new_rest, new_index)

        {[{old_gap, new_gap, preceding} | segments], old_tail, new_tail, anchor}
      end)

    Enum.reverse([{old_rest, new_rest, preceding} | segments])
  end

  # A segment's old and new gaps are paired off positionally; the leftovers on
  # whichever side is longer become deletes or inserts.
  defp reconcile({old_gap, new_gap, preceding}, actor_id) do
    pairs = Enum.zip(old_gap, new_gap)
    paired = length(pairs)

    updates =
      for {{block_id, content}, new_content} <- pairs, content != new_content do
        %{op: :update, block_id: block_id, actor_id: actor_id, content: new_content}
      end

    deletes =
      for {block_id, _content} <- Enum.drop(old_gap, paired) do
        %{op: :delete, block_id: block_id}
      end

    inserts =
      new_gap
      |> Enum.drop(paired)
      |> inserts(insertion_anchor(old_gap, paired, preceding), actor_id)

    updates ++ deletes ++ inserts
  end

  # Additions hang off the last block that both survives and sits ahead of them:
  # the final paired block of the gap, since pairing yields an `update` and an
  # update keeps its id and its place. With nothing paired, that is the block
  # before the gap -- nothing at all for the leading one, which `BlockOps` reads
  # as the head of the document.
  defp insertion_anchor(_old_gap, 0, preceding), do: preceding

  defp insertion_anchor(old_gap, paired, _preceding) do
    old_gap |> Enum.take(paired) |> List.last() |> elem(0)
  end

  # Emitted in reverse because `insert_after` puts its block immediately after
  # the anchor, and a new block's id is generated inside `BlockOps` and so cannot
  # be an anchor itself. Inserting C, then B, then A after one anchor leaves
  # A, B, C -- the right order, from a single known anchor.
  defp inserts(contents, after_block_id, actor_id) do
    for content <- Enum.reverse(contents) do
      %{
        op: :insert_after,
        after_block_id: after_block_id,
        actor_id: actor_id,
        content: content
      }
    end
  end

  # Content changes before removals before additions. Updates and deletes name
  # blocks that exist in the parent, so they are safe in any order; an insert's
  # anchor is always a paired block, which no delete in the list touches.
  defp order(operations) do
    Enum.sort_by(operations, fn
      %{op: :update} -> 0
      %{op: :delete} -> 1
      %{op: :insert_after} -> 2
    end)
  end

  # Longest common subsequence over the two content lists, as `{old_index,
  # new_index}` pairs relative to what remains after each earlier match --
  # see `segments/2`.
  defp lcs(old, new) do
    old
    |> lcs_pairs(new)
    |> relative()
  end

  defp lcs_pairs(old, new) do
    old_array = List.to_tuple(old)
    new_array = List.to_tuple(new)
    lengths = lcs_table(old_array, new_array)

    walk(old_array, new_array, lengths, 0, 0, [])
  end

  # `lengths[{i, j}]` is the LCS length of `old[i..]` and `new[j..]`, filled from
  # the far corner back so the walk that follows can pick a direction with one
  # comparison.
  defp lcs_table(old, new) do
    old_size = tuple_size(old)
    new_size = tuple_size(new)

    for i <- old_size..0//-1, j <- new_size..0//-1, reduce: %{} do
      lengths ->
        value =
          cond do
            i == old_size or j == new_size ->
              0

            elem(old, i) == elem(new, j) ->
              1 + Map.fetch!(lengths, {i + 1, j + 1})

            true ->
              max(Map.fetch!(lengths, {i + 1, j}), Map.fetch!(lengths, {i, j + 1}))
          end

        Map.put(lengths, {i, j}, value)
    end
  end

  defp walk(old, new, lengths, i, j, acc) do
    cond do
      i == tuple_size(old) or j == tuple_size(new) ->
        Enum.reverse(acc)

      elem(old, i) == elem(new, j) ->
        walk(old, new, lengths, i + 1, j + 1, [{i, j} | acc])

      Map.fetch!(lengths, {i + 1, j}) >= Map.fetch!(lengths, {i, j + 1}) ->
        walk(old, new, lengths, i + 1, j, acc)

      true ->
        walk(old, new, lengths, i, j + 1, acc)
    end
  end

  # Absolute indexes into indexes relative to the unconsumed tail, so each match
  # can be reached by splitting off what precedes it.
  defp relative(pairs) do
    {relative, _consumed} =
      Enum.map_reduce(pairs, {0, 0}, fn {i, j}, {old_used, new_used} ->
        {{i - old_used, j - new_used}, {i + 1, j + 1}}
      end)

    relative
  end
end
