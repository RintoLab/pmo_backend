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
  alias RintoPMO.Documents.BlockDiff
  alias RintoPMO.Documents.BlockMerge
  alias RintoPMO.Documents.BlockOps
  alias RintoPMO.Documents.BlockProposal
  alias RintoPMO.Documents.Document
  alias RintoPMO.Documents.DocumentBlock
  alias RintoPMO.Documents.DocumentRevision
  alias RintoPMO.Documents.Markdown
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
  Creates a document, its initial revision, and its blocks atomically.

  `attrs` takes `title`, an optional `project_id` and `change_summary`, and the
  body as `markdown` plus the `actor_id` to credit it to. The body is cut into
  blocks by `RintoPMO.Documents.Markdown` -- callers hand over a Markdown
  document, not a block list, because the grain is this layer's decision and a
  caller free to choose it would drift from every other caller.

  A missing or blank body is allowed: an empty document is a legitimate
  starting point, and there is nothing to credit to an actor either.
  """
  @impl true
  def create_document(attrs) do
    with {:ok, attrs} <- split_markdown(attrs) do
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
  end

  @doc """
  Reports how a Markdown body would be cut into blocks, creating nothing.

  The grain is this layer's decision (see `create_document/1`), so an author has
  no way to check it before committing to it. Without this they would have to
  create a document, look, and then clean up -- which is how block boundaries
  nobody wanted end up in the history.
  """
  @impl true
  def preview_blocks(markdown) when is_binary(markdown), do: Markdown.split(markdown)

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
  Records what a topic wants a document to be called.

  A title cannot travel inside a `:document` proposal's Markdown: a document's
  title is a field of the revision and is never read out of the body (see
  `RintoPMO.Documents.Markdown`), so it needs a proposal of its own.

  Like a block proposal, a topic holds one live slot and rewriting is iteration
  rather than a second opinion. Unlike one, the slot is the document -- there is
  only one title to argue about.
  """
  @impl true
  def propose_title(%Document{} = document, attrs) do
    Repo.transact(fn repo ->
      locked_document =
        Document
        |> where([candidate], candidate.id == ^document.id)
        |> lock("FOR UPDATE")
        |> repo.one!()

      latest = latest_revision!(repo, locked_document, preload_blocks?: false)

      with {:ok, proposal} <- upsert_scoped_proposal(repo, locked_document, latest, :title, attrs) do
        {:ok,
         %{proposal: proposal, live_proposals: count_live_scope(repo, locked_document, :title)}}
      end
    end)
    |> unwrap_error()
  end

  @doc """
  Records a topic's rewrite of a whole document.

  `content` is Markdown for the entire body, and is compiled here into the
  block operations that would produce it -- the only way to propose a change
  that splits, merges, inserts, removes or reorders blocks, none of which a
  block proposal can express.

  The operations are stored rather than recomputed at commit time, because they
  are what a person will have reviewed. What keeps them honest is that a
  document-scope proposal is only committable while its `base_revision_id` is
  still the document's latest revision; re-proposing recompiles against
  whatever is current, so iterating is also how a topic catches up.

  Refused when the Markdown produces the document that already exists: a
  proposal that changes nothing would commit as a revision identical to its
  parent.
  """
  @impl true
  def propose_document(%Document{} = document, attrs) do
    Repo.transact(fn repo ->
      locked_document =
        Document
        |> where([candidate], candidate.id == ^document.id)
        |> lock("FOR UPDATE")
        |> repo.one!()

      latest = latest_revision!(repo, locked_document, preload_blocks?: true)

      with {:ok, contents} <- split_proposed_markdown(attrs),
           {:ok, operations} <- compile_operations(latest, contents, attrs),
           {:ok, proposal} <-
             upsert_document_proposal(repo, locked_document, latest, operations, attrs) do
        {:ok,
         %{
           proposal: proposal,
           live_proposals: count_live_scope(repo, locked_document, :document)
         }}
      end
    end)
    |> unwrap_error()
  end

  @doc """
  Carries a whole-document proposal across the revisions that landed under it.

  A document proposal goes stale the moment anything else commits, and the
  alternative to this is throwing it away and asking the model again -- losing a
  round trip and whatever review a person had already done. So the three
  versions are merged instead: the revision it was written against, the blocks it
  wanted, and the blocks as they now stand. See
  `RintoPMO.Documents.BlockMerge` for how each block is decided.

  The merged body is then proposed exactly as a fresh one would be, so the
  content and the operations agree by construction rather than by care.

  Three answers are not success. A conflict reports the blocks two people wrote
  differently, at the same grain as any other contention, so the decision is one
  a person already knows how to make. A restructured document is refused rather
  than merged. And a proposal whose merge leaves nothing to change reports
  `no_change_proposed`: what it wanted is already true.
  """
  @impl true
  def rebase_document_proposal(%Document{} = document, proposal_id) do
    Repo.transact(fn repo ->
      locked_document =
        Document
        |> where([candidate], candidate.id == ^document.id)
        |> lock("FOR UPDATE")
        |> repo.one!()

      parent = latest_revision!(repo, locked_document, preload_blocks?: true)

      with {:ok, proposal} <- live_document_proposal(repo, locked_document, proposal_id) do
        rebase_onto(repo, locked_document, parent, proposal)
      end
    end)
    |> unwrap_error()
  end

  # Already current. Rebasing is idempotent rather than an error, so a caller may
  # ask without first working out whether it needs to.
  defp rebase_onto(
         _repo,
         _document,
         %DocumentRevision{id: id},
         %BlockProposal{
           base_revision_id: id
         } = proposal
       ) do
    {:ok, proposal}
  end

  defp rebase_onto(repo, document, parent, proposal) do
    base = revision_with_blocks!(repo, document, proposal.base_revision_id)

    with {:ok, wanted} <- replay_operations(base, proposal.block_ops),
         {:ok, contents} <- merge_onto(base, wanted, parent),
         attrs = rebased_attrs(proposal, contents),
         {:ok, split} <- split_proposed_markdown(attrs),
         {:ok, operations} <- compile_operations(parent, split, attrs) do
      upsert_document_proposal(repo, document, parent, operations, attrs)
    end
  end

  defp replay_operations(%DocumentRevision{} = base, operations) do
    case BlockOps.apply(ordered_blocks(base), operations || []) do
      {:ok, entries} -> {:ok, entries}
      {:error, code, details} -> {:error, {code, details}}
    end
  end

  defp merge_onto(%DocumentRevision{} = base, wanted, %DocumentRevision{} = parent) do
    case BlockMerge.merge(ordered_blocks(base), wanted, ordered_blocks(parent)) do
      {:ok, contents} -> {:ok, contents}
      {:conflict, details} -> {:error, {:rebase_conflict, details}}
    end
  end

  # Rejoined into a body and put back through the ordinary propose path, so the
  # stored Markdown and the stored operations cannot disagree: whatever the body
  # cuts into is what the operations produce.
  defp rebased_attrs(%BlockProposal{} = proposal, contents) do
    %{
      conversation_id: proposal.conversation_id,
      actor_id: proposal.actor_id,
      content: Enum.join(contents, "\n\n"),
      change_summary: proposal.change_summary
    }
  end

  defp revision_with_blocks!(repo, %Document{} = document, revision_id) do
    document
    |> Ecto.assoc(:revisions)
    |> where([revision], revision.id == ^revision_id)
    |> repo.one!()
    |> repo.preload(:blocks)
  end

  @doc """
  Settles a contended title in favour of one proposal.

  The document-level twin of `decide_block/4`: same argument, same outcome, a
  different slot. Two topics wanting different titles is an ordinary
  disagreement and picking one is a decision a person makes -- which is why a
  title is a scope of its own rather than something inferred from a body.
  """
  @impl true
  def decide_title(%Document{} = document, proposal_id, actor_id) do
    decide(document, :title, nil, proposal_id, actor_id)
  end

  @doc """
  Settles two topics' competing rewrites in favour of one.

  Committing one would settle it too -- that supersedes every other live
  proposal on the way through -- but only by changing the document at the same
  time. Deciding is the same argument without that: it says which rewrite the
  document is going to take, leaving when to take it to whoever commits.

  Note what this is *not* an argument with. A rewrite competes with another
  rewrite; against a block proposal there is nothing to choose, because the two
  are not alternatives (see `RintoPMO.Documents.BlockProposal`). Losing block
  proposals are superseded by the commit, not rejected by a decision here.
  """
  @impl true
  def decide_document(%Document{} = document, proposal_id, actor_id) do
    decide(document, :document, nil, proposal_id, actor_id)
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
    |> live_proposals(:block)
    |> Enum.group_by(& &1.block_id)
    |> Enum.filter(fn {_block_id, proposals} -> length(proposals) > 1 end)
    |> Enum.map(fn {block_id, proposals} ->
      %{block_id: block_id, proposals: Enum.sort_by(proposals, & &1.id)}
    end)
    |> Enum.sort_by(& &1.block_id)
  end

  @doc """
  Lists the document-level scopes more than one topic is arguing over.

  Deliberately not folded into `contentions/1`. A block contention has a place
  on the document and is settled per block; these have neither -- two topics
  wanting different titles, or different rewrites, is one argument about the
  whole document. Reporting them as contentions on every block they touch would
  offer the reader a per-block decision that would not resolve anything.
  """
  @impl true
  def scope_contentions(%Document{} = document) do
    for scope <- [:document, :title],
        proposals = live_proposals(document, scope),
        length(proposals) > 1,
        do: %{scope: scope, proposals: Enum.sort_by(proposals, & &1.id)}
  end

  @doc """
  The whole-document rewrite a topic has standing, if it has one.

  Read alongside `blocks_for_conversation/2` rather than through it: a rewrite is
  not a per-block overlay, and rendering it as one would have to invent block ids
  for text that has none yet. A caller holding one of these shows the diff in
  `block_ops` instead of the block list.
  """
  @impl true
  def document_proposal_for_conversation(%Document{} = document, conversation_id) do
    live_scoped_proposal(Repo, document, :document, conversation_id)
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
      |> live_proposals(:block)
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
    decide(document, :block, block_id, proposal_id, actor_id)
  end

  # One decision, whichever slot holds the argument: the live proposals in that
  # slot are the candidates, the named one wins and the rest are rejected. A
  # block's slot is its `block_id`; a document-level scope's slot is the scope
  # itself, there being only one of each per document.
  defp decide(%Document{} = document, scope, block_id, proposal_id, actor_id) do
    Repo.transact(fn repo ->
      decided_at = DateTime.utc_now()

      candidates =
        BlockProposal
        |> where([proposal], proposal.document_id == ^document.id and proposal.status == :live)
        |> slot(scope, block_id)
        |> lock("FOR UPDATE")
        |> repo.all()

      case Enum.split_with(candidates, &(&1.id == proposal_id)) do
        {[], _rest} ->
          {:error, {:proposal_not_found, slot_details(scope, block_id, proposal_id)}}

        {[adopted], losers} ->
          decide_all(repo, adopted, losers, actor_id, decided_at)
      end
    end)
    |> unwrap_error()
  end

  defp slot(query, :block, block_id) do
    where(query, [proposal], proposal.scope == :block and proposal.block_id == ^block_id)
  end

  defp slot(query, scope, nil), do: where(query, [proposal], proposal.scope == ^scope)

  defp slot_details(:block, block_id, proposal_id),
    do: %{proposal_id: proposal_id, block_id: block_id}

  defp slot_details(scope, nil, proposal_id), do: %{proposal_id: proposal_id, scope: scope}

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

  ## Committing a whole-document proposal

  `document_proposal_id` commits one instead, and it is named rather than
  adopted by default: a whole-document proposal settles every block, so letting
  one land implicitly would discard other topics' work without anyone choosing
  to. It cannot be combined with `block_ids` -- it is not one change among
  several, it is the whole sequence -- and it requires being current: a proposal
  compiled against an older revision would silently revert whatever landed since,
  which for a document-wide change means the entire document.

  Committing one **supersedes every other live block and document proposal**,
  because their anchors may no longer exist. Title proposals are left alone; a
  title has no anchor to lose, and an uncontested one is adopted here as it would
  be in any other commit.

  Nothing needs to happen in the other direction. Committing blocks moves the
  document on, which is what makes a standing document proposal stale, so
  whichever route lands first invalidates the other without a lock or a priority
  between them.
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
      title = title_change(repo, locked_document, attrs)

      case attr(attrs, :document_proposal_id, nil) do
        nil -> commit_blocks(repo, locked_document, parent, title, attrs)
        id -> commit_document(repo, locked_document, parent, title, id, attrs)
      end
    end)
    |> unwrap_error()
  end

  defp commit_blocks(repo, document, parent, title, attrs) do
    by_block = repo |> live_proposals(document, :block) |> Enum.group_by(& &1.block_id)

    with {:ok, block_ids} <- selected_blocks(attrs, by_block, title),
         :ok <- ensure_no_contention(block_ids, by_block),
         {:ok, adopted} <- adopted_proposals(block_ids, by_block),
         revision_attrs = revision_attrs(attrs, adopted, title),
         {:ok, revision} <- insert_revision(repo, document, parent, revision_attrs),
         :ok <- accept_all(repo, adopted ++ adopted_title(title), attr(attrs, :actor_id, nil)),
         :ok <- resolve_annotations(document, revision, attrs) do
      {:ok, revision}
    end
  end

  defp commit_document(repo, document, parent, title, proposal_id, attrs) do
    actor_id = attr(attrs, :actor_id, nil)

    with :ok <- ensure_no_block_selection(attrs),
         {:ok, proposal} <- live_document_proposal(repo, document, proposal_id),
         :ok <- ensure_compiled_against(proposal, parent),
         revision_attrs = document_revision_attrs(attrs, proposal, title),
         {:ok, revision} <- insert_revision(repo, document, parent, revision_attrs),
         :ok <- accept_all(repo, [proposal | adopted_title(title)], actor_id),
         :ok <- supersede_others(repo, document, proposal, actor_id),
         :ok <- resolve_annotations(document, revision, attrs) do
      {:ok, revision}
    end
  end

  # Not one change among several: the operations settle every block, so a
  # selection alongside them is a caller with two different ideas of what it is
  # committing.
  defp ensure_no_block_selection(attrs) do
    case attr(attrs, :block_ids, nil) do
      nil -> :ok
      _selection -> {:error, {:conflicting_commit, %{}}}
    end
  end

  defp live_document_proposal(repo, document, proposal_id) do
    BlockProposal
    |> where([proposal], proposal.document_id == ^document.id)
    |> where([proposal], proposal.id == ^proposal_id)
    |> where([proposal], proposal.scope == :document and proposal.status == :live)
    |> lock("FOR UPDATE")
    |> repo.one()
    |> case do
      nil -> {:error, {:proposal_not_found, %{proposal_id: proposal_id, scope: :document}}}
      proposal -> {:ok, proposal}
    end
  end

  # The one place a proposal's own `base_revision_id` is a conflict test rather
  # than a record. For a block proposal it could never discriminate -- every
  # topic's base is the latest revision by construction -- but a whole-document
  # proposal carries operations for blocks it did not touch, so applying an old
  # one would revert everything that landed under it. Re-propose to recompile.
  defp ensure_compiled_against(%BlockProposal{} = proposal, %DocumentRevision{} = parent) do
    if proposal.base_revision_id == parent.id do
      :ok
    else
      {:error,
       {:stale_proposal,
        %{
          proposal_id: proposal.id,
          base_revision_id: proposal.base_revision_id,
          current_revision_id: parent.id
        }}}
    end
  end

  # Their anchors may not exist in the revision this just wrote, so leaving them
  # live would mean a commit that fails on an operation nobody wrote. Title
  # proposals are untouched: a title has no anchor to lose.
  #
  # Keyed by id rather than relying on `accept_all/3` having already moved the
  # adopted one off `:live`, so the two are independent of each other's order.
  defp supersede_others(repo, document, %BlockProposal{} = adopted, actor_id) do
    BlockProposal
    |> where([proposal], proposal.document_id == ^document.id)
    |> where([proposal], proposal.status == :live and proposal.scope in [:block, :document])
    |> where([proposal], proposal.id != ^adopted.id)
    |> repo.all()
    |> then(&decide_each(repo, &1, :superseded, actor_id, DateTime.utc_now()))
  end

  defp document_revision_attrs(attrs, %BlockProposal{} = proposal, title) do
    %{
      block_ops: proposal.block_ops,
      base_revision_id: attr(attrs, :base_revision_id, nil),
      source_conversation_id: attr(attrs, :source_conversation_id, nil)
    }
    |> maybe_put(:title, title_content(title))
    # The proposer's own summary stands in when the committer wrote none: a
    # whole-document diff is what most needs a sentence in front of it.
    |> maybe_put(:change_summary, attr(attrs, :change_summary, nil) || proposal.change_summary)
  end

  defp split_markdown(attrs) do
    case attr(attrs, :markdown, nil) do
      nil ->
        {:ok, put_blocks(attrs, [])}

      markdown when is_binary(markdown) ->
        case Markdown.split(markdown) do
          {:ok, contents} -> {:ok, put_blocks(attrs, contents)}
          {:error, _reason} -> {:error, invalid_markdown(attrs)}
        end

      _other ->
        {:error, invalid_markdown(attrs)}
    end
  end

  # Every block of a new document is credited to the one actor that wrote the
  # body. Per-block authorship only starts to differ once revisions land, and
  # those carry their own `actor_id` per operation.
  defp put_blocks(attrs, contents) do
    actor_id = attr(attrs, :actor_id, nil)
    blocks = Enum.map(contents, &%{actor_id: actor_id, content: &1})

    attrs
    |> Map.drop([:markdown, "markdown", :actor_id, "actor_id", :blocks, "blocks"])
    |> Map.put(:blocks, blocks)
  end

  defp invalid_markdown(attrs) do
    %Document{}
    |> Document.creation_changeset(put_blocks(attrs, []))
    |> Changeset.add_error(:markdown, "is invalid")
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

  # Always scoped. Everything downstream of a lookup here groups by `block_id`,
  # and the document-level scopes carry none -- an unscoped query would collect
  # them under a `nil` key and hand `nil` to callers as though it were a block.
  defp live_proposals(%Document{} = document, scope), do: live_proposals(Repo, document, scope)

  defp live_proposals(repo, %Document{} = document, scope) do
    document
    |> Ecto.assoc(:proposals)
    |> where([proposal], proposal.status == :live and proposal.scope == ^scope)
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
          # This path is reached only for a block proposal. The document-level
          # scopes have their own entry point: they carry no `block_id`, so
          # `live_proposal/4` could not find their slot to iterate on.
          scope: :block,
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

  # The document-level twin of `upsert_proposal/4`. The slot is keyed by scope
  # rather than by block, and no `block_id` is written -- the check constraint
  # and the changeset both refuse one here.
  defp upsert_scoped_proposal(repo, document, latest, scope, attrs) do
    conversation_id = attr(attrs, :conversation_id, nil)
    content = attr(attrs, :content, nil)
    actor_id = attr(attrs, :actor_id, nil)

    case live_scoped_proposal(repo, document, scope, conversation_id) do
      nil ->
        %{
          document_id: document.id,
          scope: scope,
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

  defp live_scoped_proposal(repo, document, scope, conversation_id)
       when is_binary(conversation_id) do
    BlockProposal
    |> where([proposal], proposal.document_id == ^document.id)
    |> where([proposal], proposal.scope == ^scope)
    |> where([proposal], proposal.conversation_id == ^conversation_id)
    |> where([proposal], proposal.status == :live)
    |> repo.one()
  end

  defp live_scoped_proposal(_repo, _document, _scope, _conversation_id), do: nil

  # Cut by the same rules as a new document's body, because the grain is this
  # layer's decision and a proposal choosing its own would drift from every
  # revision around it.
  defp split_proposed_markdown(attrs) do
    case attr(attrs, :content, nil) do
      markdown when is_binary(markdown) ->
        case Markdown.split(markdown) do
          {:ok, contents} -> {:ok, contents}
          {:error, reason} -> {:error, {:invalid_markdown, %{reason: inspect(reason)}}}
        end

      nil ->
        # No body at all is the changeset's error to name, not a diffing failure.
        {:ok, :absent}

      _not_a_string ->
        {:error, {:invalid_markdown, %{reason: "content must be a string"}}}
    end
  end

  defp compile_operations(_latest, :absent, _attrs), do: {:ok, []}

  defp compile_operations(%DocumentRevision{} = latest, contents, attrs) do
    case BlockDiff.compile(ordered_blocks(latest), contents, attr(attrs, :actor_id, nil)) do
      [] -> {:error, {:no_change_proposed, %{}}}
      operations -> {:ok, operations}
    end
  end

  defp upsert_document_proposal(repo, document, latest, operations, attrs) do
    conversation_id = attr(attrs, :conversation_id, nil)

    compiled = %{
      actor_id: attr(attrs, :actor_id, nil),
      content: attr(attrs, :content, nil),
      block_ops: storable_operations(operations),
      base_revision_id: latest.id,
      change_summary: attr(attrs, :change_summary, nil)
    }

    case live_scoped_proposal(repo, document, :document, conversation_id) do
      nil ->
        compiled
        |> Map.merge(%{
          document_id: document.id,
          scope: :document,
          conversation_id: conversation_id
        })
        |> BlockProposal.changeset()
        |> repo.insert()

      proposal ->
        # Recompiled against the current latest revision, so a topic revising
        # its rewrite is also a topic catching up with whatever landed since.
        proposal
        |> BlockProposal.content_changeset(compiled)
        |> repo.update()
    end
  end

  defp ordered_blocks(%DocumentRevision{blocks: blocks}) when is_list(blocks) do
    Enum.sort_by(blocks, & &1.position)
  end

  # Stored as `jsonb`, which comes back with string keys and string values
  # whatever went in. Converting on the way in rather than leaving it to the
  # database means a proposal just written and one just read hold the same shape,
  # so nothing downstream has to know which it is holding. `BlockOps` reads
  # either form; the point is that there is only one.
  defp storable_operations(operations) do
    Enum.map(operations, fn operation ->
      Map.new(operation, fn
        {key, value} when is_atom(value) and not is_nil(value) ->
          {Atom.to_string(key), Atom.to_string(value)}

        {key, value} ->
          {Atom.to_string(key), value}
      end)
    end)
  end

  defp count_live(repo, document, block_id) do
    BlockProposal
    |> where([proposal], proposal.document_id == ^document.id)
    |> where([proposal], proposal.block_id == ^block_id and proposal.status == :live)
    |> repo.aggregate(:count)
  end

  defp count_live_scope(repo, document, scope) do
    BlockProposal
    |> where([proposal], proposal.document_id == ^document.id)
    |> where([proposal], proposal.scope == ^scope and proposal.status == :live)
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

  defp selected_blocks(attrs, by_block, title) do
    case attr(attrs, :block_ids, nil) do
      nil -> default_selection(by_block, title)
      [] -> nothing_to_commit_unless(title, [])
      block_ids when is_list(block_ids) -> {:ok, block_ids}
      _other -> {:error, {:invalid_block_ids, %{reason: "block_ids must be an array"}}}
    end
  end

  # Everything that can go: every block holding exactly one live proposal. A
  # contended block is left behind rather than holding up the rest, which is
  # the whole point of selecting per block.
  defp default_selection(by_block, title) do
    case for {block_id, [_only]} <- by_block, do: block_id do
      [] -> nothing_to_commit_unless(title, [])
      block_ids -> {:ok, Enum.sort(block_ids)}
    end
  end

  # A retitling is a change, so a commit carrying one is not empty even with no
  # block to go with it.
  defp nothing_to_commit_unless(nil, _block_ids), do: {:error, {:nothing_to_commit, %{}}}
  defp nothing_to_commit_unless(_title, block_ids), do: {:ok, block_ids}

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

  defp revision_attrs(attrs, adopted, title) do
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
    |> maybe_put(:title, title_content(title))
    |> maybe_put(:change_summary, attr(attrs, :change_summary, nil))
  end

  # What settles this revision's title, if anything at all.
  #
  # A proposal is adopted the way a block's is: exactly one live one is
  # uncontested and goes, more than one is an argument and is left behind rather
  # than holding up the rest of the commit.
  #
  # A title in `attrs` is somebody typing one. It wins, and it settles nothing --
  # a person choosing their own words is not a decision about anybody's proposal.
  defp title_change(repo, document, attrs) do
    case attr(attrs, :title, nil) do
      nil ->
        case live_proposals(repo, document, :title) do
          [only] -> {:adopted, only}
          _none_or_contended -> nil
        end

      typed ->
        {:typed, typed}
    end
  end

  defp title_content(nil), do: nil
  defp title_content({:typed, title}), do: title
  defp title_content({:adopted, %BlockProposal{content: content}}), do: content

  defp adopted_title({:adopted, proposal}), do: [proposal]
  defp adopted_title(_typed_or_absent), do: []

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
