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

  ## Moves, only where the identity is not a guess

  A block whose text is unchanged but whose place is not comes out of the
  matching as a delete and an insert. Where that pair is unambiguous -- exactly
  one removal and exactly one addition carrying that text -- the two are folded
  back into a `move_after`, and the block keeps its id, its annotations and its
  history.

  Where it is ambiguous -- the same paragraph twice, or text that was reworded
  on its way across -- the delete and the insert stand. Telling those apart
  needs a similarity measure rather than the equality this uses, and guessing
  wrong silently rewrites the wrong paragraph's history. A reviewer sees a
  removal and an addition, which is what actually happened as far as anything
  can tell.

  ## Insertions come with their ids, and with their order

  Every insertion allocates the `block_id` it is going to have, so the paragraph
  a person reviews is the paragraph that lands rather than one that appears at
  commit time. Several insertions into one gap are one **run**: they share
  `run_id` and are numbered by `run_ordinal` in the order they were written, so
  taking the first and the third still leaves them in that order. The run is
  emitted back to front, each member anchored on the same block, which is the
  order a plain sequential apply needs.

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
      iex> [operation] = BlockDiff.compile(blocks, ["One", "Two"], "actor")
      iex> {operation.op, operation.after_block_id, operation.content}
      {:insert_after, "a", "Two"}
  """
  @spec compile([DocumentBlock.t()], [String.t()], UUIDv7.t()) :: [operation()]
  def compile(blocks, contents, actor_id) when is_list(blocks) and is_list(contents) do
    old = Enum.map(blocks, &{&1.block_id, &1.content})

    old
    |> segments(contents)
    |> Enum.flat_map(&reconcile(&1, actor_id))
    |> fold_moves(Map.new(old))
    |> order()
  end

  # A removal and an addition carrying the same text are one block that moved,
  # but only where nothing else could be meant: one removal saying it and one
  # addition saying it. Two identical paragraphs shifting around each other have
  # no answer, and inventing one attaches an id -- and everything hanging off
  # it -- to the wrong words.
  defp fold_moves(operations, old_by_id) do
    removed =
      unique_by_content(
        for %{op: :delete, block_id: block_id} <- operations,
            do: {Map.get(old_by_id, block_id), block_id}
      )

    added =
      unique_by_content(
        for %{op: :insert_after} = insertion <- operations,
            do: {insertion.content, insertion}
      )

    moved =
      for {content, block_id} <- removed,
          insertion = added[content],
          do: {content, block_id, insertion}

    if moved == [] do
      operations
    else
      apply_moves(operations, moved)
    end
  end

  defp apply_moves(operations, moved) do
    dropped_deletes = MapSet.new(moved, fn {_content, block_id, _insertion} -> block_id end)

    dropped_inserts =
      MapSet.new(moved, fn {_content, _block_id, insertion} -> insertion.block_id end)

    # The move takes the insertion's place in its run. Where the rest of that run
    # goes depends on it: a block written second in a gap sits after the block
    # written first, and that stays true when the first turns out to be a
    # paragraph that moved rather than one that appeared.
    moves =
      for {_content, block_id, insertion} <- moved,
          insertion.after_block_id != block_id do
        %{op: :move_after, block_id: block_id, after_block_id: insertion.after_block_id}
        |> carry_run(insertion)
      end

    kept =
      Enum.reject(operations, fn
        %{op: :delete, block_id: block_id} -> MapSet.member?(dropped_deletes, block_id)
        %{op: :insert_after, block_id: block_id} -> MapSet.member?(dropped_inserts, block_id)
        _other -> false
      end)

    kept ++ moves
  end

  defp carry_run(operation, %{run_id: run_id, run_ordinal: ordinal}),
    do: Map.merge(operation, %{run_id: run_id, run_ordinal: ordinal})

  defp carry_run(operation, _lone_insertion), do: operation

  defp unique_by_content(pairs) do
    pairs
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Enum.flat_map(fn
      {content, [only]} -> [{content, only}]
      {_content, _ambiguous} -> []
    end)
    |> Map.new()
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

  # Emitted back to front because `insert_after` puts its block immediately after
  # the anchor: inserting C, then B, then A after one anchor leaves A, B, C --
  # the right order, from a single known anchor.
  #
  # `run_ordinal` is the order they were *written*, which is not that order and
  # is the one that matters later: a person publishing the first and the third
  # of three has to get them the right way round without the second, and the
  # anchor alone cannot say. A lone insertion is not a run; there is no sequence
  # to remember.
  defp inserts([_only] = contents, after_block_id, actor_id) do
    for content <- contents do
      %{
        op: :insert_after,
        block_id: UUIDv7.generate(),
        after_block_id: after_block_id,
        actor_id: actor_id,
        content: content
      }
    end
  end

  defp inserts(contents, after_block_id, actor_id) do
    run_id = UUIDv7.generate()

    contents
    |> Enum.with_index()
    |> Enum.reverse()
    |> Enum.map(fn {content, ordinal} ->
      %{
        op: :insert_after,
        block_id: UUIDv7.generate(),
        after_block_id: after_block_id,
        actor_id: actor_id,
        content: content,
        run_id: run_id,
        run_ordinal: ordinal
      }
    end)
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

  # Text, then reorderings, then additions, then removals.
  #
  # An anchor names where something sits in the document the operations produce,
  # not where it sat before. So a block has to reach its new place before
  # anything is hung off it: an insertion after a block that is about to move
  # would otherwise be left behind where that block used to be. Nothing needs
  # the other order -- a move's anchor is always a block that already exists.
  #
  # Removals come last so that an insertion or a move anchored on a block this
  # same list deletes still lands where it was meant to.
  defp order(operations) do
    Enum.sort_by(operations, fn
      %{op: :update} -> 0
      %{op: :move_after} -> 1
      %{op: :insert_after} -> 2
      %{op: :delete} -> 3
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
