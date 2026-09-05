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
  on. Within each gap, normalized 3-gram similarity finds edited blocks with
  enough textual evidence to keep their ids. A maximum-weight ordered matching
  prevents those identities from crossing when content is reordered.

  Similar matches divide a gap into smaller runs. Each unmatched run falls back
  to positional pairing, preserving the conservative behaviour for wholesale
  rewrites where similarity offers no evidence. Inserts and deletes are only
  introduced when a similarity match demonstrates the positional pairing would
  attach an existing id to the wrong content.
  """

  alias RintoPMO.Documents.DocumentBlock

  @similarity_threshold 0.5
  @weight_epsilon 1.0e-12

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

  # Similar matches establish identities within a gap. The runs between them
  # retain positional pairing, which is the safest fallback when the text gives
  # no evidence that one changed block corresponds to another.
  defp reconcile({old_gap, new_gap, preceding}, actor_id) do
    pairs = gap_pairs(old_gap, new_gap)
    paired_old = MapSet.new(pairs, &elem(&1, 0))
    paired_new = Map.new(pairs, fn {old_index, new_index} -> {new_index, old_index} end)

    updates =
      for {old_index, new_index} <- pairs,
          {block_id, content} = Enum.at(old_gap, old_index),
          new_content = Enum.at(new_gap, new_index),
          content != new_content do
        %{op: :update, block_id: block_id, actor_id: actor_id, content: new_content}
      end

    deletes =
      for {{block_id, _content}, index} <- Enum.with_index(old_gap),
          not MapSet.member?(paired_old, index) do
        %{op: :delete, block_id: block_id}
      end

    inserts =
      new_gap
      |> Enum.with_index()
      |> Enum.reject(fn {_content, index} -> Map.has_key?(paired_new, index) end)
      |> Enum.chunk_by(fn {_content, index} ->
        insertion_anchor(old_gap, pairs, index, preceding)
      end)
      |> Enum.flat_map(fn [{_content, index} | _] = run ->
        contents = Enum.map(run, &elem(&1, 0))
        inserts(contents, insertion_anchor(old_gap, pairs, index, preceding), actor_id)
      end)

    updates ++ deletes ++ inserts
  end

  defp gap_pairs(old_gap, new_gap) do
    old_contents = Enum.map(old_gap, &elem(&1, 1))
    matches = similarity_matches(old_contents, new_gap)

    {pairs, old_start, new_start} =
      Enum.reduce(matches, {[], 0, 0}, fn {old_index, new_index}, {pairs, old_start, new_start} ->
        fallback = positional_pairs(old_start, old_index, new_start, new_index)
        {pairs ++ fallback ++ [{old_index, new_index}], old_index + 1, new_index + 1}
      end)

    pairs ++ positional_pairs(old_start, length(old_gap), new_start, length(new_gap))
  end

  defp positional_pairs(old_start, old_end, new_start, new_end) do
    count = min(old_end - old_start, new_end - new_start)

    for offset <- indexes(count) do
      {old_start + offset, new_start + offset}
    end
  end

  defp indexes(0), do: []
  defp indexes(count), do: 0..(count - 1)

  # An insertion follows the nearest target block before it that keeps an old
  # id. If there is no such block in this gap, it follows the exact LCS anchor
  # before the gap (or nil at the head of the document).
  defp insertion_anchor(old_gap, pairs, new_index, preceding) do
    case pairs |> Enum.take_while(fn {_old, new} -> new < new_index end) |> List.last() do
      {old_index, _new_index} -> old_gap |> Enum.at(old_index) |> elem(0)
      nil -> preceding
    end
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

  # Maximum-weight ordered matching, with the pair sequence as a total tie
  # breaker. Keeping the lexicographically earliest sequence makes repeated or
  # equally similar text deterministic.
  defp similarity_matches([], _new), do: []
  defp similarity_matches(_old, []), do: []

  defp similarity_matches(old, new) do
    old = List.to_tuple(old)
    new = List.to_tuple(new)
    old_size = tuple_size(old)
    new_size = tuple_size(new)
    empty = %{weight: 0.0, pairs: []}

    table =
      Enum.reduce(0..old_size, %{}, fn index, table ->
        Map.put(table, {index, new_size}, empty)
      end)

    table =
      Enum.reduce(0..new_size, table, fn index, table ->
        Map.put(table, {old_size, index}, empty)
      end)

    table =
      for i <- (old_size - 1)..0//-1, j <- (new_size - 1)..0//-1, reduce: table do
        table ->
          score = similarity(elem(old, i), elem(new, j))

          candidates = [Map.fetch!(table, {i + 1, j}), Map.fetch!(table, {i, j + 1})]

          candidates =
            if score >= @similarity_threshold do
              tail = Map.fetch!(table, {i + 1, j + 1})
              [%{weight: score + tail.weight, pairs: [{i, j} | tail.pairs]} | candidates]
            else
              candidates
            end

          Map.put(table, {i, j}, Enum.reduce(candidates, &better_solution/2))
      end

    table |> Map.fetch!({0, 0}) |> Map.fetch!(:pairs)
  end

  defp better_solution(candidate, best) do
    cond do
      candidate.weight > best.weight + @weight_epsilon -> candidate
      best.weight > candidate.weight + @weight_epsilon -> best
      candidate.pairs < best.pairs -> candidate
      true -> best
    end
  end

  defp similarity(left, right) do
    left = trigrams(left)
    right = trigrams(right)

    overlap =
      Enum.reduce(left, 0, fn {gram, count}, total ->
        total + min(count, Map.get(right, gram, 0))
      end)

    2 * overlap / (gram_count(left) + gram_count(right))
  end

  defp trigrams(content) do
    graphemes =
      content
      |> String.trim()
      |> String.downcase()
      |> String.replace(~r/\s+/u, " ")
      |> String.graphemes()

    grams =
      case graphemes do
        [] -> [""]
        [_] -> [Enum.join(graphemes)]
        [_, _] -> [Enum.join(graphemes)]
        _ -> graphemes |> Enum.chunk_every(3, 1, :discard) |> Enum.map(&Enum.join/1)
      end

    Enum.frequencies(grams)
  end

  defp gram_count(grams), do: grams |> Map.values() |> Enum.sum()

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
