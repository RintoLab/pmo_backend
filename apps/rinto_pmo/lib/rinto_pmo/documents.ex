defmodule RintoPMO.Documents do
  @moduledoc """
  The context for immutable, block-based documents.

  ## Proposals

  Between two revisions sits a working copy, and it is not a second set of
  blocks: it is the latest revision plus the `RintoPMO.Documents.BlockProposal`
  rows standing against it. One working copy per document, shared by every
  topic, so the document never forks -- disagreement is pushed down to the
  block, where it is resolved by a person choosing rather than by merging text.

  Revisions are produced only by `commit_proposals/2`. That is the one place
  where a new revision, the annotations it settles, and the proposals it
  accepts all move together, and they move in a single transaction because a
  revision that resolved nothing -- or resolutions pointing at a revision that
  was never written -- would each be worse than failing.
  """

  use RintoPMO, :context

  alias Ecto.Changeset
  alias RintoPMO.Documents.BlockOps
  alias RintoPMO.Documents.BlockProposal
  alias RintoPMO.Documents.Document
  alias RintoPMO.Documents.DocumentBlock
  alias RintoPMO.Documents.DocumentRevision
  alias RintoPMO.Utils

  @behaviour RintoPMO.Documents.Behaviour

  @doc """
  Lists non-archived documents with their latest revision, newest first.
  """
  @impl true
  def list_documents(filter) do
    latest_revision_query =
      from revision in DocumentRevision,
        where: revision.document_id == parent_as(:document).id,
        order_by: [desc: revision.id],
        limit: 1

    Document
    |> from(as: :document)
    |> where([document], is_nil(document.archived_at))
    |> filter_documents(filter)
    |> join(:inner_lateral, [document: _document], revision in subquery(latest_revision_query),
      on: true
    )
    |> order_by([_document, revision], desc: revision.id)
    |> select([document, revision], {document, revision})
    |> Repo.all()
    |> Enum.map(fn {document, revision} ->
      %{document | latest_revision: revision}
    end)
  end

  @doc """
  Fetches a document with its latest revision and blocks.
  """
  @impl true
  def get_document!(id) do
    document = Repo.get!(Document, id)
    %{document | latest_revision: latest_revision!(document, preload_blocks?: true)}
  end

  @doc """
  Creates a document, its initial revision, and optional blocks atomically.
  """
  @impl true
  def create_document(attrs) do
    %Document{}
    |> Document.creation_changeset(attrs)
    |> Repo.insert()
    |> case do
      {:ok, %Document{revisions: [revision]} = document} ->
        {:ok, %{document | latest_revision: revision}}

      {:error, %Changeset{} = changeset} ->
        {:error, changeset}
    end
  end

  @doc """
  Idempotently archives a document.
  """
  @impl true
  def archive_document(%Document{} = document) do
    document
    |> Document.archive_changeset()
    |> Repo.update()
  end

  @doc """
  Lists a document's immutable revisions, newest first.
  """
  @impl true
  def list_revisions(%Document{} = document) do
    document
    |> Ecto.assoc(:revisions)
    |> order_by([revision], desc: revision.id)
    |> Repo.all()
  end

  @doc """
  Fetches one revision and its ordered block snapshot.
  """
  @impl true
  def get_revision!(%Document{} = document, id) do
    document
    |> Ecto.assoc(:revisions)
    |> where([revision], revision.id == ^id)
    |> Repo.one!()
    |> Repo.preload(:blocks)
  end

  @doc """
  Applies block operations to the latest snapshot and creates a new revision.
  """
  @impl true
  def create_revision(%Document{} = document, attrs) do
    Repo.transact(fn repo ->
      locked_document =
        Document
        |> where([candidate], candidate.id == ^document.id)
        |> lock("FOR UPDATE")
        |> repo.one!()

      parent = latest_revision!(repo, locked_document, preload_blocks?: true)
      insert_revision(repo, locked_document, parent, attrs)
    end)
    |> unwrap_error()
  end

  @doc """
  Lists a document's proposals, newest first.

  `filter` accepts `:status`, `:block_id` and `:conversation_id`.
  """
  @impl true
  def list_proposals(%Document{} = document, filter) when is_map(filter) do
    document
    |> Ecto.assoc(:proposals)
    |> filter_proposals(filter)
    |> order_by([proposal], desc: proposal.id)
    |> Repo.all()
  end

  @doc """
  Fetches one proposal scoped to its document.
  """
  @impl true
  def get_proposal!(%Document{} = document, id) do
    document
    |> Ecto.assoc(:proposals)
    |> where([proposal], proposal.id == ^id)
    |> Repo.one!()
  end

  @doc """
  Records what a topic wants a block to say.

  A topic already holding a live proposal on the block has it rewritten in
  place rather than gaining a second one: five rounds of "tighten this" are one
  intent iterating, and the contention count would be meaningless otherwise.

  Answers with the number of live proposals now standing on that block, so the
  caller learns it has walked into a contention without having to ask again --
  and, more usefully, so the topic can be told before it builds further on the
  assumption that its version will win.
  """
  @impl true
  def propose_block(%Document{} = document, attrs) do
    Repo.transact(fn repo ->
      locked_document =
        Document
        |> where([candidate], candidate.id == ^document.id)
        |> lock("FOR UPDATE")
        |> repo.one!()

      latest = latest_revision!(repo, locked_document, preload_blocks?: true)
      block_id = attr(attrs, :block_id, nil)

      with :ok <- ensure_known_block(latest, block_id),
           {:ok, proposal} <- upsert_proposal(repo, locked_document, latest, attrs) do
        {:ok, %{proposal: proposal, live_proposals: count_live(repo, locked_document, block_id)}}
      end
    end)
    |> unwrap_error()
  end

  @doc """
  Lists the blocks with more than one live proposal, and those proposals.

  Two live proposals on one block *is* the conflict test. No version numbers,
  no locks: topics write their own slots, so nothing overwrites anything and
  there is no race to detect.
  """
  @impl true
  def contentions(%Document{} = document) do
    document
    |> live_proposals()
    |> Enum.group_by(& &1.block_id)
    |> Enum.filter(fn {_block_id, proposals} -> length(proposals) > 1 end)
    |> Enum.map(fn {block_id, proposals} ->
      %{block_id: block_id, proposals: Enum.sort_by(proposals, & &1.id)}
    end)
    |> Enum.sort_by(& &1.block_id)
  end

  @doc """
  Reads a document as one topic sees it: the latest revision, with that topic's
  own proposals standing in, plus the bare fact that others exist.

  The other proposals' text is deliberately withheld. The point is not to let a
  topic reconcile the versions itself -- that is the human's decision -- but to
  stop it building on the assumption that it is alone in the block.
  """
  @impl true
  def blocks_for_conversation(%Document{} = document, conversation_id) do
    proposals =
      document
      |> live_proposals()
      |> Enum.group_by(& &1.block_id)

    document
    |> latest_revision!(preload_blocks?: true)
    |> Map.fetch!(:blocks)
    |> Enum.sort_by(& &1.position)
    |> Enum.map(fn block ->
      block_proposals = Map.get(proposals, block.block_id, [])
      {own, others} = Enum.split_with(block_proposals, &(&1.conversation_id == conversation_id))
      proposal = List.first(own)

      %{
        block_id: block.block_id,
        position: block.position,
        content: if(proposal, do: proposal.content, else: block.content),
        proposal_id: proposal && proposal.id,
        proposed?: proposal != nil,
        other_proposals: length(others)
      }
    end)
  end

  @doc """
  Settles a contended block by rejecting every proposal but one.

  The winner stays `live`: deciding a contention is not committing it. It has
  merely stopped being contended, and still has to go through
  `commit_proposals/2` like any other pending change -- which is also why the
  winner carries no decision stamp yet, leaving `decided_by_actor_id` on the
  rejected proposals to record who ended the argument and when.

  The only other way out of a contention is to open a topic about it. There is
  no manual merge: a third version nobody asked for is exactly what this design
  refuses to produce. See `RintoPMO.Documents.BlockProposal` on why the losers
  are kept rather than deleted.
  """
  @impl true
  def decide_block(%Document{} = document, block_id, proposal_id, actor_id) do
    Repo.transact(fn repo ->
      decided_at = DateTime.utc_now()

      candidates =
        BlockProposal
        |> where([proposal], proposal.document_id == ^document.id)
        |> where([proposal], proposal.block_id == ^block_id and proposal.status == :live)
        |> lock("FOR UPDATE")
        |> repo.all()

      case Enum.split_with(candidates, &(&1.id == proposal_id)) do
        {[], _rest} ->
          {:error, {:proposal_not_found, %{proposal_id: proposal_id, block_id: block_id}}}

        {[adopted], losers} ->
          decide_all(repo, adopted, losers, actor_id, decided_at)
      end
    end)
    |> unwrap_error()
  end

  @doc """
  Turns the chosen proposals into a revision.

  Three things happen here and they happen together, in one transaction: the
  revision is written, the annotations named as settled are resolved against
  it, and the proposals it used become `accepted`. Commit is the only natural
  moment for an annotation to be resolved -- there is no other point at which
  someone has both decided and changed the document -- so a revision written
  without its resolutions, or resolutions pointing at a revision that failed to
  write, would both leave the record lying.

  `attrs` takes `actor_id`, `base_revision_id`, and optionally `block_ids`
  (defaulting to every uncontended block holding a live proposal),
  `resolve_annotation_ids`, `source_conversation_id`, `title` and
  `change_summary`.

  A block with an undecided contention cannot be committed, but it does not
  hold up the rest: selection is per block, so the others go through and that
  one waits for a decision.
  """
  @impl true
  def commit_proposals(%Document{} = document, attrs) do
    Repo.transact(fn repo ->
      locked_document =
        Document
        |> where([candidate], candidate.id == ^document.id)
        |> lock("FOR UPDATE")
        |> repo.one!()

      parent = latest_revision!(repo, locked_document, preload_blocks?: true)
      by_block = repo |> live_proposals(locked_document) |> Enum.group_by(& &1.block_id)

      with {:ok, block_ids} <- selected_blocks(attrs, by_block),
           :ok <- ensure_no_contention(block_ids, by_block),
           {:ok, adopted} <- adopted_proposals(block_ids, by_block),
           revision_attrs = revision_attrs(attrs, adopted),
           {:ok, revision} <- insert_revision(repo, locked_document, parent, revision_attrs),
           :ok <- accept_all(repo, adopted, attr(attrs, :actor_id, nil)),
           :ok <- resolve_annotations(locked_document, revision, attrs) do
        {:ok, revision}
      end
    end)
    |> unwrap_error()
  end

  defp filter_documents(query, :all), do: query

  defp filter_documents(query, :unassigned) do
    where(query, [document], is_nil(document.project_id))
  end

  defp filter_documents(query, {:project, project_id}) do
    where(query, [document], document.project_id == ^project_id)
  end

  defp insert_revision(repo, document, parent, attrs) do
    revision = %DocumentRevision{
      id: next_revision_id(parent),
      document_id: document.id,
      parent_id: parent.id
    }

    changeset = DocumentRevision.next_changeset(revision, parent, attrs)

    cond do
      not changeset.valid? ->
        {:error, changeset}

      Changeset.get_field(changeset, :base_revision_id) != parent.id ->
        {:error, {:stale_document, %{current_revision_id: parent.id}}}

      true ->
        case BlockOps.apply(parent.blocks, attr(attrs, :block_ops, [])) do
          {:ok, block_entries} ->
            changeset
            |> put_block_snapshots(block_entries)
            |> repo.insert()

          {:error, code, details} ->
            {:error, {code, details}}
        end
    end
  end

  defp put_block_snapshots(changeset, block_entries) do
    block_changesets =
      block_entries
      |> Enum.with_index()
      |> Enum.map(fn {entry, position} ->
        %DocumentBlock{block_id: entry.block_id, position: position}
        |> DocumentBlock.changeset(%{actor_id: entry.actor_id, content: entry.content})
      end)

    Changeset.put_assoc(changeset, :blocks, block_changesets)
  end

  defp latest_revision!(%Document{} = document, options) do
    latest_revision!(Repo, document, options)
  end

  defp latest_revision!(repo, %Document{} = document, options) do
    revision =
      document
      |> Ecto.assoc(:revisions)
      |> order_by([candidate], desc: candidate.id)
      |> limit(1)
      |> repo.one!()

    if Keyword.fetch!(options, :preload_blocks?) do
      repo.preload(revision, :blocks)
    else
      revision
    end
  end

  defp next_revision_id(%DocumentRevision{} = parent) do
    timestamp = max(System.system_time(:millisecond), UUIDv7.timestamp(parent.id) + 1)
    UUIDv7.generate(timestamp)
  end

  defp attr(attrs, key, default) do
    cond do
      Map.has_key?(attrs, key) -> Map.get(attrs, key)
      Map.has_key?(attrs, Atom.to_string(key)) -> Map.get(attrs, Atom.to_string(key))
      true -> default
    end
  end

  # Proposals

  defp filter_proposals(query, filter) do
    Enum.reduce(filter, query, fn
      {:status, status}, query ->
        where(query, [proposal], proposal.status == ^status)

      {:block_id, block_id}, query ->
        where(query, [proposal], proposal.block_id == ^block_id)

      {:conversation_id, conversation_id}, query ->
        where(query, [proposal], proposal.conversation_id == ^conversation_id)

      {_other, _value}, query ->
        query
    end)
  end

  defp live_proposals(%Document{} = document), do: live_proposals(Repo, document)

  defp live_proposals(repo, %Document{} = document) do
    document
    |> Ecto.assoc(:proposals)
    |> where([proposal], proposal.status == :live)
    |> repo.all()
  end

  # Rejected early rather than at commit: BlockOps would fail there with an
  # error about an operation the caller never wrote, long after the mistake.
  defp ensure_known_block(%DocumentRevision{blocks: blocks}, block_id) do
    if Enum.any?(blocks, &(&1.block_id == block_id)) do
      :ok
    else
      {:error, {:unknown_block, %{block_id: block_id}}}
    end
  end

  defp upsert_proposal(repo, document, latest, attrs) do
    block_id = attr(attrs, :block_id, nil)
    conversation_id = attr(attrs, :conversation_id, nil)
    content = attr(attrs, :content, nil)
    actor_id = attr(attrs, :actor_id, nil)

    case live_proposal(repo, document, block_id, conversation_id) do
      nil ->
        %{
          document_id: document.id,
          block_id: block_id,
          conversation_id: conversation_id,
          actor_id: actor_id,
          content: content,
          base_revision_id: latest.id
        }
        |> BlockProposal.changeset()
        |> repo.insert()

      proposal ->
        proposal
        |> BlockProposal.content_changeset(%{actor_id: actor_id, content: content})
        |> repo.update()
    end
  end

  defp live_proposal(repo, document, block_id, conversation_id)
       when is_binary(block_id) and is_binary(conversation_id) do
    BlockProposal
    |> where([proposal], proposal.document_id == ^document.id)
    |> where([proposal], proposal.block_id == ^block_id)
    |> where([proposal], proposal.conversation_id == ^conversation_id)
    |> where([proposal], proposal.status == :live)
    |> repo.one()
  end

  # Missing ids fall through to the changeset, which names them properly.
  defp live_proposal(_repo, _document, _block_id, _conversation_id), do: nil

  defp count_live(repo, document, block_id) do
    BlockProposal
    |> where([proposal], proposal.document_id == ^document.id)
    |> where([proposal], proposal.block_id == ^block_id and proposal.status == :live)
    |> repo.aggregate(:count)
  end

  defp decide_all(repo, adopted, losers, actor_id, decided_at) do
    with :ok <- decide_each(repo, losers, :rejected, actor_id, decided_at) do
      {:ok, adopted}
    end
  end

  defp decide_each(repo, proposals, status, actor_id, decided_at) do
    Enum.reduce_while(proposals, :ok, fn proposal, :ok ->
      case decide_one(repo, proposal, status, actor_id, decided_at) do
        {:ok, _proposal} -> {:cont, :ok}
        {:error, changeset} -> {:halt, {:error, changeset}}
      end
    end)
  end

  defp decide_one(repo, proposal, status, actor_id, decided_at) do
    proposal
    |> BlockProposal.decision_changeset(status, actor_id, decided_at)
    |> repo.update()
  end

  # Commit

  defp selected_blocks(attrs, by_block) do
    case attr(attrs, :block_ids, nil) do
      nil -> default_selection(by_block)
      [] -> {:error, {:nothing_to_commit, %{}}}
      block_ids when is_list(block_ids) -> {:ok, block_ids}
      _other -> {:error, {:invalid_block_ids, %{reason: "block_ids must be an array"}}}
    end
  end

  # Everything that can go: every block holding exactly one live proposal. A
  # contended block is left behind rather than holding up the rest, which is
  # the whole point of selecting per block.
  defp default_selection(by_block) do
    case for {block_id, [_only]} <- by_block, do: block_id do
      [] -> {:error, {:nothing_to_commit, %{}}}
      block_ids -> {:ok, Enum.sort(block_ids)}
    end
  end

  defp ensure_no_contention(block_ids, by_block) do
    case Enum.filter(block_ids, &(length(Map.get(by_block, &1, [])) > 1)) do
      [] -> :ok
      contended -> {:error, {:unresolved_contention, %{block_ids: Enum.sort(contended)}}}
    end
  end

  defp adopted_proposals(block_ids, by_block) do
    block_ids
    |> Enum.reduce_while({:ok, []}, fn block_id, {:ok, adopted} ->
      case Map.get(by_block, block_id, []) do
        [proposal] -> {:cont, {:ok, [proposal | adopted]}}
        [] -> {:halt, {:error, {:no_live_proposal, %{block_id: block_id}}}}
      end
    end)
    |> case do
      {:ok, adopted} -> {:ok, Enum.reverse(adopted)}
      error -> error
    end
  end

  defp revision_attrs(attrs, adopted) do
    block_ops =
      Enum.map(adopted, fn proposal ->
        %{
          op: :update,
          block_id: proposal.block_id,
          actor_id: proposal.actor_id,
          content: proposal.content
        }
      end)

    %{
      block_ops: block_ops,
      base_revision_id: attr(attrs, :base_revision_id, nil),
      source_conversation_id: attr(attrs, :source_conversation_id, nil)
    }
    |> maybe_put(:title, attr(attrs, :title, nil))
    |> maybe_put(:change_summary, attr(attrs, :change_summary, nil))
  end

  # `title` is absent rather than nil when unset, because the revision
  # changeset reads its absence as "keep the parent's".
  defp maybe_put(attrs, _key, nil), do: attrs
  defp maybe_put(attrs, key, value), do: Map.put(attrs, key, value)

  defp accept_all(repo, adopted, actor_id) do
    decide_each(repo, adopted, :accepted, actor_id, DateTime.utc_now())
  end

  defp resolve_annotations(document, revision, attrs) do
    attrs
    |> attr(:resolve_annotation_ids, [])
    |> List.wrap()
    |> Enum.reduce_while(:ok, fn annotation_id, :ok ->
      case resolve_annotation(document, revision, annotation_id) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  # Scoped to the document, so an annotation from elsewhere cannot be marked
  # resolved by a revision that could not have touched it. An annotation always
  # belongs to a document and its resolving revision is in that same document,
  # so the two line up without anything having to check.
  defp resolve_annotation(document, revision, annotation_id) do
    context = annotations()
    annotation = context.get_annotation!(document, annotation_id)

    case context.resolve_annotation(annotation, %{resolved_by_revision_id: revision.id}) do
      {:ok, _annotation} -> :ok
      {:error, changeset} -> {:error, changeset}
    end
  rescue
    Ecto.NoResultsError ->
      {:error, {:annotation_not_found, %{annotation_id: annotation_id}}}
  end

  defp unwrap_error({:ok, value}), do: {:ok, value}
  defp unwrap_error({:error, %Changeset{} = changeset}), do: {:error, changeset}
  defp unwrap_error({:error, {code, details}}), do: {:error, code, details}

  defp annotations, do: Utils.module(:annotations)
end
