defmodule RintoPMO.Documents.BlockMerge do
  @moduledoc """
  Carries a whole-document rewrite across a revision that landed under it.

  A `:document` proposal is only committable while it is compiled against the
  latest revision, because its operations cover blocks it did not touch and an
  old one would revert whatever arrived in between. Without this, the recovery is
  to throw the proposal away and ask the model again -- losing both a round trip
  and whatever review a person had already done.

  So instead the three versions are merged, block by block:

      base   the revision the proposal was written against
      theirs the blocks the proposal wanted, as its operations produce them
      ours   the blocks as they now stand

  Each block that exists in `base` is decided on its own:

    * only the proposal touched it -- take the proposal's text
    * only the other side touched it -- take theirs, the proposal has no opinion
    * both, to the same text -- they agree
    * both, differently -- **conflict**
    * the proposal removed it and the other side had edited it -- **conflict**,
      because dropping it would discard that edit silently

  Blocks the proposal added are kept. Conflicts are reported rather than
  resolved: choosing between two people's words is the one thing this system
  never does on its own.

  ## Why the conflict grain is the block

  Because that is the grain everything else already argues at. A rebase that
  cannot merge produces block ids, which is exactly what a contention is, so the
  decision a person then makes is the one they already know how to make.

  ## What it refuses

  A merge only happens when `ours` differs from `base` by edited content --
  same blocks, same order. If the document was restructured underneath, the
  proposal is refused rather than merged, because reconciling two structural
  changes needs a policy nobody has chosen.

  That is a narrower limit than it sounds. A commit built from block proposals
  can only ever produce `update` operations, so it never restructures anything;
  and a commit built from another document proposal supersedes every live
  proposal on its way through, so nothing survives it to be rebased. Only the
  direct revision API can restructure a document under a standing proposal.
  """

  @type entry :: %{required(:block_id) => term(), required(:content) => String.t()}

  @type conflict :: %{required(:reason) => atom(), optional(atom()) => term()}

  @doc """
  Merges a proposal's blocks onto the ones that now stand.

  Answers with the merged block contents in order, ready to be rejoined into a
  body and recompiled, or with the conflict that stopped it.
  """
  @spec merge([entry()], [entry()], [entry()]) :: {:ok, [String.t()]} | {:conflict, conflict()}
  def merge(base, theirs, ours) when is_list(base) and is_list(theirs) and is_list(ours) do
    with :ok <- ensure_only_edited(base, ours) do
      resolve(base, theirs, ours)
    end
  end

  # Same blocks in the same order, differing only in what they say. Compared as
  # a list rather than a set so that a reorder is caught too.
  defp ensure_only_edited(base, ours) do
    if ids(base) == ids(ours) do
      :ok
    else
      {:conflict,
       %{
         reason: :restructured,
         added: ids(ours) -- ids(base),
         removed: ids(base) -- ids(ours)
       }}
    end
  end

  defp resolve(base, theirs, ours) do
    base_by_id = by_id(base)
    ours_by_id = by_id(ours)
    kept = MapSet.new(ids(theirs))

    {contents, conflicts} =
      Enum.map_reduce(theirs, [], fn entry, conflicts ->
        case decide(entry, base_by_id, ours_by_id) do
          {:take, content} -> {content, conflicts}
          {:conflict, block_id} -> {entry.content, [block_id | conflicts]}
        end
      end)

    case Enum.reverse(conflicts) ++ dropped_conflicts(base, kept, ours_by_id) do
      [] -> {:ok, contents}
      block_ids -> {:conflict, %{reason: :diverged, block_ids: Enum.uniq(block_ids)}}
    end
  end

  defp decide(entry, base_by_id, ours_by_id) do
    case Map.fetch(base_by_id, entry.block_id) do
      # Added by the proposal, so nobody else has an opinion about it.
      :error ->
        {:take, entry.content}

      {:ok, base_content} ->
        ours_content = Map.fetch!(ours_by_id, entry.block_id)

        cond do
          entry.content == ours_content -> {:take, entry.content}
          entry.content == base_content -> {:take, ours_content}
          ours_content == base_content -> {:take, entry.content}
          true -> {:conflict, entry.block_id}
        end
    end
  end

  # A block the proposal removed. Dropping it is fine if it still says what it
  # said; if the other side edited it in the meantime, removing it now would
  # throw that edit away without anyone seeing it.
  defp dropped_conflicts(base, kept, ours_by_id) do
    for %{block_id: block_id, content: base_content} <- base,
        not MapSet.member?(kept, block_id),
        Map.fetch!(ours_by_id, block_id) != base_content,
        do: block_id
  end

  defp ids(entries), do: Enum.map(entries, & &1.block_id)
  defp by_id(entries), do: Map.new(entries, &{&1.block_id, &1.content})
end
