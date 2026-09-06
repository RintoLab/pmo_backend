defmodule RintoPMO.Documents.ProposalPlan do
  @moduledoc """
  What a standing proposal still means against the document as it now stands,
  and the operations a chosen set of them would run.

  A proposal is written against one revision and reviewed against another. The
  gap between the two is not something a person should have to close by hand:
  re-basing a proposal would rewrite what somebody already read, and asking the
  model again throws away the review. So nothing is rewritten, and the
  comparison is done at read time instead -- three versions, every time:

      original   the revision the proposal was written against
      current    the latest revision
      proposed   what this proposal wants, fixed forever

  ## Three questions, kept apart

  `state/3` answers *can this still be applied, and does it need a person*.
  `relevance/2` answers *has the thing that was chosen changed since the choice
  was made*. They are different questions and were one for a while: a paragraph
  three sections away changing is not a reason to ask somebody to re-confirm a
  deletion, and it is not a reason to refuse it either.

  `operations/3` answers *what would running these actually do*, and is the only
  one of the three that has an opinion about order.

  ## What it will not do

  It will not merge two people's words, and it will not guess. Where the block a
  proposal wants to rewrite says something else now, that is
  `{:needs_confirmation, :content_diverged}` and it stops there until somebody
  adopts it against what the block says today. Where a `move`'s anchor is gone,
  that is `{:not_applicable, :anchor_missing}` -- an inventable position is
  still an invented one.
  """

  alias RintoPMO.Documents.BlockProposal
  alias RintoPMO.Documents.DocumentRevision

  @type snapshot :: %{
          blocks: %{optional(UUIDv7.t()) => String.t()},
          order: [UUIDv7.t()],
          title: String.t() | nil
        }

  @type state ::
          :applicable
          | :already_applied
          | {:needs_confirmation, atom()}
          | {:not_applicable, atom()}

  @doc """
  The parts of a revision this module compares: what each block says, what order
  the blocks are in, and the title.
  """
  @spec snapshot(DocumentRevision.t()) :: snapshot()
  def snapshot(%DocumentRevision{blocks: blocks, title: title}) when is_list(blocks) do
    ordered = Enum.sort_by(blocks, & &1.position)

    %{
      blocks: Map.new(ordered, &{&1.block_id, &1.content}),
      order: Enum.map(ordered, & &1.block_id),
      title: title
    }
  end

  @doc """
  Whether this proposal can still be applied to `current`, and what stands in
  the way if it cannot.

  `base` is the snapshot of the revision the proposal was written against, or
  `nil` when that revision can no longer be read -- in which case nothing can be
  said about whether the target has moved, and a person is asked.
  """
  @spec state(BlockProposal.t(), snapshot() | nil, snapshot()) :: state()
  def state(%BlockProposal{scope: :title} = proposal, base, current) do
    cond do
      current.title == proposal.content -> :already_applied
      is_nil(base) -> {:needs_confirmation, :base_unreadable}
      current.title == base.title -> :applicable
      true -> {:needs_confirmation, :title_diverged}
    end
  end

  def state(%BlockProposal{operation: :update} = proposal, base, current) do
    case Map.fetch(current.blocks, proposal.block_id) do
      :error ->
        {:not_applicable, :target_deleted}

      {:ok, said} ->
        cond do
          said == proposal.content -> :already_applied
          is_nil(base) -> {:needs_confirmation, :base_unreadable}
          said == Map.get(base.blocks, proposal.block_id) -> :applicable
          true -> {:needs_confirmation, :content_diverged}
        end
    end
  end

  # A deletion whose target is already gone got what it wanted. It is satisfied
  # rather than accepted: nobody's publish did this, and recording one would put
  # a revision on it that never touched it.
  def state(%BlockProposal{operation: :delete} = proposal, base, current) do
    case Map.fetch(current.blocks, proposal.block_id) do
      :error ->
        :already_applied

      {:ok, said} ->
        cond do
          is_nil(base) -> {:needs_confirmation, :base_unreadable}
          said == Map.get(base.blocks, proposal.block_id) -> :applicable
          # Deleting text nobody has read is how an edit disappears without
          # anyone seeing it happen.
          true -> {:needs_confirmation, :target_rewritten}
        end
    end
  end

  def state(%BlockProposal{operation: :insert} = proposal, _base, current) do
    cond do
      Map.has_key?(current.blocks, proposal.block_id) -> :already_applied
      anchor_missing?(proposal.after_block_id, current) -> {:not_applicable, :anchor_missing}
      true -> :applicable
    end
  end

  def state(%BlockProposal{operation: :move} = proposal, _base, current) do
    cond do
      not Map.has_key?(current.blocks, proposal.block_id) ->
        {:not_applicable, :target_deleted}

      anchor_missing?(proposal.after_block_id, current) ->
        {:not_applicable, :anchor_missing}

      predecessor(current.order, proposal.block_id) == proposal.after_block_id ->
        :already_applied

      true ->
        :applicable
    end
  end

  @doc """
  What a choice between competing candidates was made against.

  Only the part of the document the proposal actually argues about: the text it
  rewrites, the place it moves to, the title it renames. A paragraph elsewhere
  changing does not make somebody's choice stale, and treating the whole
  document as the subject of every choice would make every publish invalidate
  every other pending decision.
  """
  @spec relevance(BlockProposal.t(), snapshot()) :: term()
  def relevance(%BlockProposal{scope: :title}, snapshot), do: {:title, snapshot.title}

  def relevance(%BlockProposal{operation: operation} = proposal, snapshot)
      when operation in [:update, :delete] do
    {:content, Map.get(snapshot.blocks, proposal.block_id)}
  end

  def relevance(%BlockProposal{operation: :insert} = proposal, snapshot) do
    {:gap,
     Map.has_key?(snapshot.blocks, proposal.after_block_id) or is_nil(proposal.after_block_id),
     successor(snapshot.order, proposal.after_block_id)}
  end

  def relevance(%BlockProposal{operation: :move} = proposal, snapshot) do
    {:place, Map.has_key?(snapshot.blocks, proposal.block_id),
     Map.has_key?(snapshot.blocks, proposal.after_block_id) or is_nil(proposal.after_block_id),
     predecessor(snapshot.order, proposal.block_id)}
  end

  @doc """
  The block operations that apply `proposals` to `current`, in an order that
  leaves every one of them meaning what it meant on its own.

  Text, then reorderings, then insertions, then removals. An anchor names where
  something sits in the document that comes out, not where it sat before, so a
  block has to reach its new place before anything is hung off it -- an
  insertion after a paragraph that is about to move would otherwise be left
  behind where that paragraph used to be. Removals run last so that an insertion
  anchored on a paragraph this same publish deletes still lands where it was
  reviewed.

  `run_siblings` maps a run id to that run's proposals, newest state included,
  so that consecutive insertions from one propose call keep their written order
  however many of them a person takes and in whatever order the takes happen.
  Publishing the first and the third and then the second leaves the same
  document as publishing all three at once.
  """
  @spec operations([BlockProposal.t()], snapshot(), %{optional(UUIDv7.t()) => [BlockProposal.t()]}) ::
          {:ok, [map()]} | {:error, {atom(), map()}}
  def operations(proposals, current, run_siblings) do
    deleted =
      for %{operation: :delete} = proposal <- proposals, into: MapSet.new(), do: proposal.block_id

    moves = for %{operation: :move} = proposal <- proposals, do: proposal

    placed =
      for %{operation: operation} = proposal <- proposals,
          operation in [:insert, :move],
          into: MapSet.new(),
          do: proposal.block_id

    with :ok <- ensure_move_anchors_survive(moves, deleted),
         {:ok, ordered_moves} <- order_moves(moves) do
      updates =
        for %{scope: :block, operation: :update} = proposal <- proposals do
          %{
            op: :update,
            block_id: proposal.block_id,
            actor_id: proposal.actor_id,
            content: proposal.content
          }
        end

      inserts =
        proposals
        |> Enum.filter(&(&1.operation == :insert))
        |> order_inserts()
        |> Enum.map(fn proposal ->
          %{
            op: :insert_after,
            block_id: proposal.block_id,
            after_block_id: insertion_anchor(proposal, current, placed, run_siblings),
            actor_id: proposal.actor_id,
            content: proposal.content
          }
        end)

      move_ops =
        Enum.map(ordered_moves, fn proposal ->
          %{op: :move_after, block_id: proposal.block_id, after_block_id: proposal.after_block_id}
        end)

      deletes =
        for %{operation: :delete} = proposal <- proposals do
          %{op: :delete, block_id: proposal.block_id}
        end

      {:ok, updates ++ move_ops ++ inserts ++ deletes}
    end
  end

  defp ensure_move_anchors_survive(moves, deleted) do
    case Enum.filter(moves, &MapSet.member?(deleted, &1.after_block_id)) do
      [] -> :ok
      blocked -> {:error, {:unresolved_dependency, %{proposal_ids: Enum.map(blocked, & &1.id)}}}
    end
  end

  # A move whose destination is another block being moved has to wait for it,
  # or it lands beside a block that is about to leave. Following those edges is
  # a topological sort, and a cycle in them is two moves that each want to be
  # after the other -- which describes no document.
  defp order_moves(moves) do
    by_block = Map.new(moves, &{&1.block_id, &1})

    Enum.reduce_while(moves, {:ok, [], MapSet.new()}, fn move, {:ok, ordered, done} ->
      case visit(move, by_block, ordered, done, []) do
        {:ok, ordered, done} -> {:cont, {:ok, ordered, done}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, ordered, _done} -> {:ok, Enum.reverse(ordered)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp visit(move, by_block, ordered, done, path) do
    cond do
      MapSet.member?(done, move.id) ->
        {:ok, ordered, done}

      move.id in path ->
        {:error, {:move_cycle, %{proposal_ids: [move.id | path] |> Enum.uniq() |> Enum.sort()}}}

      true ->
        after_dependency(move, by_block, ordered, done, [move.id | path])
    end
  end

  defp after_dependency(move, by_block, ordered, done, path) do
    case Map.fetch(by_block, move.after_block_id) do
      :error -> {:ok, [move | ordered], MapSet.put(done, move.id)}
      {:ok, earlier} -> place_after(move, visit(earlier, by_block, ordered, done, path))
    end
  end

  defp place_after(move, {:ok, ordered, done}),
    do: {:ok, [move | ordered], MapSet.put(done, move.id)}

  defp place_after(_move, error), do: error

  # Members of one run, in the order they were written; anything else after
  # them, in a stable order of its own.
  defp order_inserts(inserts) do
    Enum.sort_by(inserts, &{&1.run_id || "", &1.run_ordinal || 0, &1.id})
  end

  # The nearest earlier member of this insertion's run that is going to be where
  # the run says it is -- published already, or going in with this one. Falling
  # back to the anchor the proposal was written with, which is where the run
  # started.
  #
  # A run member can be a move rather than an insertion: a paragraph that turned
  # out to have been relocated rather than written. It counts only once it has
  # actually been moved, because until then the block is still sitting somewhere
  # else entirely and anchoring on it would put the new text there.
  defp insertion_anchor(%BlockProposal{run_id: nil} = proposal, _current, _placed, _siblings),
    do: proposal.after_block_id

  defp insertion_anchor(proposal, current, placed, run_siblings) do
    run_siblings
    |> Map.get(proposal.run_id, [])
    |> Enum.filter(fn sibling ->
      (sibling.run_ordinal || 0) < (proposal.run_ordinal || 0) and
        in_run_position?(sibling, current, placed)
    end)
    |> Enum.max_by(& &1.run_ordinal, fn -> nil end)
    |> case do
      nil -> proposal.after_block_id
      sibling -> sibling.block_id
    end
  end

  defp in_run_position?(%BlockProposal{operation: :insert} = sibling, current, placed) do
    Map.has_key?(current.blocks, sibling.block_id) or MapSet.member?(placed, sibling.block_id)
  end

  defp in_run_position?(%BlockProposal{operation: :move} = sibling, _current, placed) do
    sibling.status == :accepted or MapSet.member?(placed, sibling.block_id)
  end

  defp in_run_position?(%BlockProposal{}, _current, _placed), do: false

  defp anchor_missing?(nil, _snapshot), do: false
  defp anchor_missing?(block_id, snapshot), do: not Map.has_key?(snapshot.blocks, block_id)

  defp predecessor(order, block_id) do
    case Enum.find_index(order, &(&1 == block_id)) do
      nil -> nil
      0 -> nil
      index -> Enum.at(order, index - 1)
    end
  end

  defp successor(order, nil), do: List.first(order)

  defp successor(order, block_id) do
    case Enum.find_index(order, &(&1 == block_id)) do
      nil -> nil
      index -> Enum.at(order, index + 1)
    end
  end
end
