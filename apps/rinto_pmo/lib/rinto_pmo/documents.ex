defmodule RintoPMO.Documents do
  @moduledoc """
  The context for immutable, block-based documents.

  ## Proposals

  Between two revisions sits a working copy, and it is not a second set of
  blocks: it is the latest revision plus the `RintoPMO.Documents.BlockProposal`
  rows standing against it. One working copy per document, shared by every
  topic, so the document never forks -- disagreement is pushed down to the
  block, where it is resolved by a person choosing rather than by merging text.

  ## Who wrote a proposal is not a caller's to say

  Proposing is how an AI writes; a person writes by creating a revision. So the
  author of a proposal is the AI that wrote it, derived here rather than
  accepted as a parameter -- the only version of this that cannot be got wrong.
  A caller able to name an author can name the wrong one, and attributing a
  model's work to a person erases the distinction the whole review flow rests
  on, silently, since nothing downstream could tell.

  Which AI depends on how the topic is configured:

    * an actor topic answers for itself -- the assistant it is talking to
    * a plain chat has no assistant, only the provider and model the person
      picked, and a model configuration is not something a block can be
      credited to. Those writes are signed with the default actor, which exists
      from setup and is configured by nobody: see `RintoPMO.Actors.Actor`

  What is derived therefore differs; that it is derived, and never supplied,
  does not.

  The mirror of the rule is that deciding and committing *do* take an actor.
  Those are a person's actions, and there is no topic to derive them from.

  Revisions are produced only by `commit_proposals/2`. That is the one place
  where a new revision, the annotations it settles, and the proposals it
  accepts all move together, and they move in a single transaction because a
  revision that settled nothing -- or confirmations pointing at a revision that
  was never written -- would each be worse than failing.
  """

  use RintoPMO, :context

  alias Ecto.Changeset
  alias RintoPMO.Documents.BlockDiff
  alias RintoPMO.Documents.BlockOps
  alias RintoPMO.Documents.BlockProposal
  alias RintoPMO.Documents.Document
  alias RintoPMO.Documents.DocumentBlock
  alias RintoPMO.Documents.DocumentRevision
  alias RintoPMO.Documents.Markdown
  alias RintoPMO.Documents.ProposalPlan
  alias RintoPMO.Documents.Revisions
  alias RintoPMO.Links
  alias RintoPMO.References.Guard
  alias RintoPMO.Utils

  @behaviour RintoPMO.Documents.Behaviour

  @doc """
  Lists non-archived documents with their latest revision, newest first.

  `filter` accepts `:project` -- a project id, or `:unassigned` for documents
  belonging to none -- and `:status`. An absent key filters nothing, which is
  the only sane default here: every document is created `:draft`, so a list that
  quietly dropped them would hide nearly everything, starting with whatever was
  written most recently.
  """
  @impl true
  def list_documents(filter) when is_map(filter) do
    Document
    |> from(as: :document)
    |> where([document], is_nil(document.archived_at))
    |> filter_documents(filter)
    |> join(:inner, [document: document], revision in subquery(Revisions.latest()),
      on: revision.document_id == document.id
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

  Every document is created `:draft`, and `attrs` has no say in it -- see
  `RintoPMO.Documents.Document`. Only `formalize_document/1` clears the flag.

  ## No `project_id` means the default project

  Omitting it files the document in the project reserved as the default (see
  `RintoPMO.Projects`) rather than leaving it belonging to nothing. Most notes
  are not written with a project in mind, and asking for one before anything
  can be written down is a question at exactly the wrong moment -- but a
  document filed nowhere is one nothing lists, which is how a note is lost.

  Sending `project_id` explicitly still wins, including a client that has
  always sent one.
  """
  @impl true
  def create_document(attrs) do
    with :ok <- Guard.check(attr(attrs, :markdown, nil)),
         {:ok, attrs} <- put_default_project(attrs),
         {:ok, author_id} <- document_author(attrs),
         {:ok, attrs} <- split_markdown(attrs, author_id) do
      Repo.transact(&insert_document(&1, attrs))
    end
    |> unwrap_error()
  end

  # Creation does not go through `insert_revision/4` -- the first revision and
  # its blocks are nested into the document's own changeset -- so it needs its
  # own call into the index. Without this, a document created with references
  # in its body would have none of them indexed until something else happened
  # to save it.
  defp insert_document(repo, attrs) do
    %Document{}
    |> Document.creation_changeset(attrs)
    |> repo.insert()
    |> case do
      {:ok, %Document{revisions: [revision]} = document} ->
        Links.sync_document(repo, revision)
        {:ok, %{document | latest_revision: revision}}

      {:error, %Changeset{} = changeset} ->
        {:error, changeset}
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
  Moves a document to another project.

  ## What this is for

  A document that landed in the wrong project, corrected shortly after it was
  written. The case it exists for is an AI writing a document in a topic
  without a `project_id`, which files it in the default project (see
  `create_document/1`) rather than the one the discussion was about.

  **It is not a general re-filing tool, and there is deliberately no check
  stopping it from behaving as one.** An `:applied` document has already been
  filed as a work breakdown, and the tasks that came out of it took a copy of
  the project id at that moment (`RintoPMO.Tasks.file_breakdown/1`) -- moving
  the document afterwards leaves the work where it was, with no way to move it
  after the fact. Refusing the call would be the stricter answer; the honest
  one is that this is a single-operator system and the rule is a habit, not a
  guard. Move documents that were just written, not documents something else
  has already acted on.

  ## A person's action

  Reachable only over HTTP, with no counterpart in the agent CLI -- the same
  rule `formalize_document/1` follows. Which project a document belongs to is
  the judgement an author got wrong, so an author is not the one who gets to
  correct it.

  Nothing else has to move with it. No copy of `project_id` is kept anywhere:
  search filters by joining the document row (`RintoPMO.Search`), and the
  earlier attempt to denormalise it onto blocks was removed for exactly the
  reason this function would have broken it. One column, and everything
  downstream is in line the moment it is written.

  A `project_id` that names nothing comes back as a changeset error, and so
  does a missing one: a document filed nowhere is one nothing lists, which is
  what `create_document/1` reaches for the default project to avoid.
  """
  @impl true
  def refile_document(%Document{} = document, project_id) do
    document
    |> Document.refile_changeset(project_id)
    |> Repo.update()
  end

  @doc """
  Idempotently archives a document.

  Nothing else has to happen. Search leaves archived content out by joining to
  this flag rather than by reading a copy of it, so putting a document away
  takes it out of results the moment this row is written -- there is no
  projection to bring back into line, and nothing that could be forgotten.
  """
  @impl true
  def archive_document(%Document{} = document) do
    document
    |> Document.archive_changeset()
    |> Repo.update()
  end

  @doc """
  Idempotently adopts a `:draft` document as a `:formal` one.

  The one way out of the state every document is created in, and a person's
  action alone: it records that somebody looked at a document and decided it
  counts, which is not a judgement its author can make on its own behalf.
  Nothing about the content moves -- no revision, no proposal -- because adoption
  is about standing, not text.

  There is no way back. A document that turns out not to be worth keeping is
  archived, not returned to `:draft`; and one already consumed downstream is
  refused outright. See `RintoPMO.Documents.Document`.
  """
  @impl true
  def formalize_document(%Document{} = document) do
    document
    |> Document.formalize_changeset()
    |> Repo.update()
  end

  @doc """
  Marks a document as consumed by whatever downstream took it.

  The end of the axis: nothing moves out of `:applied`, and asking twice is
  refused rather than answered idempotently -- filing one document as two work
  breakdowns is exactly what the state exists to prevent.

  Composes inside a caller's transaction, which is the point. Filing a
  breakdown creates tasks and consumes the document, and either both happen or
  the document is still there to be filed.
  """
  @impl true
  def apply_document(%Document{} = document) do
    document
    |> Document.apply_changeset()
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
    with :ok <- Guard.check_all(block_op_contents(attrs)) do
      insert_new_revision(document, attrs)
    end
    |> unwrap_error()
  end

  # Every body a revision carries, checked before any of it is written: a
  # caller told about the first bad address would fix it and be refused again
  # for the second.
  defp block_op_contents(attrs) do
    attrs
    |> attr(:block_ops, [])
    |> List.wrap()
    |> Enum.map(fn
      operation when is_map(operation) -> attr(operation, :content, nil)
      _other -> nil
    end)
  end

  defp insert_new_revision(%Document{} = document, attrs) do
    Repo.transact(fn repo ->
      locked_document =
        Document
        |> where([candidate], candidate.id == ^document.id)
        |> lock("FOR UPDATE")
        |> repo.one!()

      parent = latest_revision!(repo, locked_document, preload_blocks?: true)
      insert_revision(repo, locked_document, parent, attrs)
    end)
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
  The read a review screen is made of: the proposals, and what each of them
  still means against the document as it now stands.

  One snapshot, under a shared lock, so that the comparison and the revision id
  it was computed against cannot disagree. A client handed last week's diff
  beside this morning's revision id would publish against the wrong thing and
  have no way of knowing.

  Nothing is written here. Reading a proposal does not adopt it, does not
  refresh what an earlier choice was made against, and does not tidy anything
  up -- a read that quietly confirmed a stale decision would be the one way this
  could overwrite somebody's words without anybody choosing to.
  """
  @impl true
  def review_proposals(%Document{} = document, filter) when is_map(filter) do
    Repo.transact(fn repo ->
      locked_document =
        Document
        |> where([candidate], candidate.id == ^document.id)
        |> lock("FOR SHARE")
        |> repo.one!()

      revision = latest_revision!(repo, locked_document, preload_blocks?: true)

      proposals =
        locked_document
        |> Ecto.assoc(:proposals)
        |> filter_proposals(filter)
        |> order_by([proposal], desc: proposal.id)
        |> repo.all()

      {:ok,
       %{
         current_revision_id: revision.id,
         proposals: describe_proposals(repo, locked_document, proposals, revision)
       }}
    end)
    |> unwrap_error()
  end

  @doc """
  Lists a topic's live proposals, across every document it has touched.

  Not scoped to a document, unlike `list_proposals/2`, because the caller is a
  topic wanting to know what it currently has standing -- and a topic is not
  about one document. `RintoPMO.Agent.PromptBuilder` uses it to hand a revived
  session back its own work.
  """
  @impl true
  def live_conversation_proposals(conversation_id) when is_binary(conversation_id) do
    BlockProposal
    |> where([proposal], proposal.conversation_id == ^conversation_id)
    |> where([proposal], proposal.status == :live)
    |> order_by([proposal], asc: proposal.id)
    |> Repo.all()
  end

  @doc """
  Everything one topic has standing, grouped by the document it is against.

  The read behind a review screen for a discussion that changed several
  documents. `live_conversation_proposals/1` answers the same question as a flat
  list for a prompt; this one adds the two things a person needs before deciding
  and a client cannot work out for itself:

    * the document each group is against, with its current title -- an id is not
      something to review against
    * whether each proposal is **contended**: somebody else's live proposal
      claims the same thing this one does

  `contended` is computed here rather than left to a caller because the
  alternative is a request to `/contentions` per document, which is a query per
  group to answer a boolean the same query already knows.

  Documents come back in the order this topic first touched them, which is the
  order the discussion went in. Proposals within a document keep their own
  ascending order, for the same reason.

  Only what is still live. A rejected proposal is a record of why something was
  not chosen -- valuable, and not part of what is waiting to be published.
  """
  @impl true
  def conversation_working_set(conversation_id) when is_binary(conversation_id) do
    mine = live_conversation_proposals(conversation_id)

    case Enum.map(mine, & &1.document_id) |> Enum.uniq() do
      [] -> []
      document_ids -> group_working_set(mine, document_ids)
    end
  end

  defp group_working_set(mine, document_ids) do
    documents = Map.new(working_set_documents(document_ids), &{&1.id, &1})
    contended = contended_proposals(document_ids)

    mine
    |> Enum.group_by(& &1.document_id)
    |> Enum.map(fn {document_id, proposals} ->
      document = Map.fetch!(documents, document_id)
      details = describe_proposals(Repo, document, proposals, document.latest_revision)

      %{
        document: document,
        proposals:
          Enum.map(details, fn detail ->
            %{proposal: detail, contended: MapSet.member?(contended, detail.proposal.id)}
          end)
      }
    end)
    # The order the topic reached each document, which is the order somebody
    # reviewing the discussion read it happen.
    |> Enum.sort_by(fn %{proposals: [%{proposal: first} | _rest]} -> first.proposal.id end)
  end

  defp working_set_documents(document_ids) do
    pairs =
      Document
      |> from(as: :document)
      |> where([document], document.id in ^document_ids)
      |> join(:inner, [document: document], revision in subquery(Revisions.latest()),
        on: revision.document_id == document.id
      )
      |> select([document, revision], {document, revision})
      |> Repo.all()

    revisions =
      pairs
      |> Enum.map(&elem(&1, 1))
      |> Repo.preload(:blocks)
      |> Map.new(&{&1.id, &1})

    Enum.map(pairs, fn {document, revision} ->
      %{document | latest_revision: Map.fetch!(revisions, revision.id)}
    end)
  end

  # Every proposal in these documents that something else is competing with. One
  # query for the whole set rather than one per document: the answer is a
  # membership test, and the set is small.
  defp contended_proposals(document_ids) do
    BlockProposal
    |> where([proposal], proposal.document_id in ^document_ids)
    |> where([proposal], proposal.status == :live)
    |> Repo.all()
    |> Enum.group_by(& &1.document_id)
    |> Enum.flat_map(fn {_document_id, proposals} ->
      for {id, [_first | _rest]} <- conflict_map(proposals), do: id
    end)
    |> MapSet.new()
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
  Records what a topic wants one block to say.

  `base_revision_id` is the revision whose text the topic actually read. It is
  not a version to be bumped and not a rebase: it says what this proposal is a
  change *from*, so that a later reader can tell an untouched paragraph from a
  contested one. Naming the latest revision without having read it -- looking one
  up at request time to fill the field in -- is the one thing that would make
  every comparison downstream lie.

  A topic re-proposing exactly what it already has standing keeps that proposal,
  id and all. Anything else is a different modification: a new row, and the one
  it replaces becomes `superseded`. Ids are never rewritten, because a message
  citing one has to keep saying what it said.
  """
  @impl true
  def propose_block(%Document{} = document, attrs) do
    with :ok <- Guard.check(attr(attrs, :content, nil)) do
      propose(document, attrs, &block_intent/3)
    end
  end

  @doc """
  Records what a topic wants a document to be called.

  A title cannot travel inside Markdown: a document's title is a field of the
  revision and is never read out of the body (see
  `RintoPMO.Documents.Markdown`), so it needs a proposal of its own. It is not
  otherwise a special case -- two titles compete like two rewrites of a
  paragraph, either may be adopted, and neither has to be.
  """
  @impl true
  def propose_title(%Document{} = document, attrs) do
    with :ok <- Guard.check(attr(attrs, :content, nil)) do
      propose(document, attrs, &title_intent/3)
    end
  end

  @doc """
  Takes a topic's rewrite of a whole document and records it as the separate
  changes it is made of.

  `content` is Markdown for the entire body. It is compiled against the revision
  the topic read -- `base_revision_id` -- into updates, insertions, deletions and
  moves, and each of those becomes a proposal of its own. Whole-document Markdown
  is therefore an input format and nothing else: there is no row holding it, no
  id naming it, and nothing to adopt or publish that means "all of this".

  That is the point. A rewrite that tightens two paragraphs, adds a section and
  drops a stale note is four things a person will have four opinions about, and
  a single object holding all four offers them no way to say so.

  Re-proposing replaces only what this topic had standing in this document's
  body. Its title proposal is untouched -- a title is a different question --
  and so is every other topic's work.

  Refused when the Markdown produces the document that already exists: nothing
  to propose is not a way of withdrawing what was proposed before, and a topic
  meaning that says so with `reject`.
  """
  @impl true
  def propose_document(%Document{} = document, attrs) do
    with :ok <- Guard.check(attr(attrs, :content, nil)) do
      propose(document, attrs, &document_intent/3)
    end
  end

  defp propose(%Document{} = document, attrs, intent) do
    Repo.transact(fn repo ->
      locked_document =
        Document
        |> where([candidate], candidate.id == ^document.id)
        |> lock("FOR UPDATE")
        |> repo.one!()

      with {:ok, author_id} <- proposal_author(attrs),
           {:ok, base} <- fetch_base_revision(repo, locked_document, attrs),
           {:ok, wanted, replaces} <- intent.(base, author_id, attrs),
           {:ok, proposals, superseded} <-
             reconcile_proposals(repo, locked_document, base, author_id, attrs, wanted, replaces) do
        {:ok, proposed_result(repo, locked_document, proposals, superseded)}
      end
    end)
    |> unwrap_error()
  end

  # One block's new text. What it replaces is this topic's standing rewrite of
  # that same block -- not its move of it, and not its deletion of it, which are
  # different intents about the same paragraph and compose with this one.
  defp block_intent(%DocumentRevision{} = base, actor_id, attrs) do
    block_id = attr(attrs, :block_id, nil)
    content = attr(attrs, :content, nil)
    said = base.blocks |> Enum.find(&(&1.block_id == block_id)) |> then(&(&1 && &1.content))

    cond do
      is_nil(block_id) or is_nil(said) ->
        {:error, {:unknown_block, %{block_id: block_id}}}

      said == content ->
        {:error, {:no_change_proposed, %{block_id: block_id}}}

      true ->
        {:ok,
         [
           %{
             scope: :block,
             operation: :update,
             block_id: block_id,
             content: content,
             actor_id: actor_id
           }
         ], {:slots, [{block_id, :update}]}}
    end
  end

  defp title_intent(%DocumentRevision{} = base, actor_id, attrs) do
    content = attr(attrs, :content, nil)

    if base.title == content do
      {:error, {:no_change_proposed, %{scope: :title}}}
    else
      {:ok, [%{scope: :title, operation: :update, content: content, actor_id: actor_id}],
       {:scope, :title}}
    end
  end

  defp document_intent(%DocumentRevision{} = base, actor_id, attrs) do
    with {:ok, contents} <- split_proposed_markdown(attrs),
         {:ok, operations} <- compile_operations(base, contents, actor_id) do
      {:ok, Enum.map(operations, &intent_of(&1, actor_id)), {:scope, :block}}
    end
  end

  defp intent_of(%{op: :update} = operation, actor_id) do
    %{
      scope: :block,
      operation: :update,
      block_id: operation.block_id,
      content: operation.content,
      actor_id: actor_id
    }
  end

  defp intent_of(%{op: :insert_after} = operation, actor_id) do
    %{
      scope: :block,
      operation: :insert,
      block_id: operation.block_id,
      after_block_id: operation.after_block_id,
      content: operation.content,
      run_id: Map.get(operation, :run_id),
      run_ordinal: Map.get(operation, :run_ordinal),
      actor_id: actor_id
    }
  end

  defp intent_of(%{op: :delete} = operation, actor_id) do
    %{scope: :block, operation: :delete, block_id: operation.block_id, actor_id: actor_id}
  end

  defp intent_of(%{op: :move_after} = operation, actor_id) do
    %{
      scope: :block,
      operation: :move,
      block_id: operation.block_id,
      after_block_id: operation.after_block_id,
      run_id: Map.get(operation, :run_id),
      run_ordinal: Map.get(operation, :run_ordinal),
      actor_id: actor_id
    }
  end

  @doc """
  Saves the checkbox against one proposal, and nothing else.

  Ticking is not adopting and not publishing: it is a person marking what they
  are thinking of taking, so that closing the screen does not lose it. There is
  no sequence number and no ordering protocol -- a later save wins over an
  earlier one, because that is what saving a checkbox means.

  What it will not do is let a tick stand in for a decision nobody made. A
  proposal cannot be ticked while something else is competing with it and
  nothing has been adopted, and it cannot be ticked when it could not be applied
  at all.
  """
  @impl true
  def stage_proposal(%Document{} = document, proposal_id, staged) when is_boolean(staged) do
    Repo.transact(fn repo ->
      locked_document =
        Document
        |> where([candidate], candidate.id == ^document.id)
        |> lock("FOR UPDATE")
        |> repo.one!()

      revision = latest_revision!(repo, locked_document, preload_blocks?: true)

      with {:ok, proposal} <- fetch_proposal(repo, locked_document, proposal_id, lock?: true),
           {:ok, described} <- ensure_stageable(repo, locked_document, proposal, revision, staged),
           {:ok, updated} <- write_stage(repo, proposal, described, staged) do
        {:ok, describe(repo, locked_document, updated, revision)}
      end
    end)
    |> unwrap_error()
  end

  # Already out of the pending set, and already unticked with it. Saying so again
  # is not an error; there is nothing left to change.
  defp write_stage(_repo, proposal, :settled, _staged), do: {:ok, proposal}

  defp write_stage(repo, proposal, :pending, staged) do
    proposal |> BlockProposal.staged_changeset(staged) |> repo.update()
  end

  defp ensure_stageable(_repo, _document, %BlockProposal{status: status}, _revision, false)
       when status != :live,
       do: {:ok, :settled}

  defp ensure_stageable(
         _repo,
         _document,
         %BlockProposal{status: status} = proposal,
         _revision,
         _staged
       )
       when status != :live,
       do: {:error, {:proposal_not_live, %{proposal_id: proposal.id, status: status}}}

  defp ensure_stageable(_repo, _document, %BlockProposal{}, _revision, false), do: {:ok, :pending}

  defp ensure_stageable(repo, document, %BlockProposal{} = proposal, revision, true) do
    detail = describe(repo, document, proposal, revision)

    cond do
      detail.state == :already_applied ->
        {:error,
         {:proposal_not_applicable, %{proposal_id: proposal.id, reason: :already_applied}}}

      detail.state == :not_applicable ->
        {:error, {:proposal_not_applicable, %{proposal_id: proposal.id, reason: detail.reason}}}

      detail.state == :needs_confirmation and not detail.adopted ->
        {:error, {:needs_reconfirmation, %{proposal_id: proposal.id, reason: detail.reason}}}

      detail.conflicting_proposal_ids != [] and not detail.adopted ->
        {:error,
         {:unresolved_contention,
          %{proposal_id: proposal.id, conflicting_proposal_ids: detail.conflicting_proposal_ids}}}

      true ->
        {:ok, :pending}
    end
  end

  @doc """
  Chooses this candidate over the ones competing with it.

  Adopting settles an argument; it does not publish anything and it does not
  tick anything. What it writes is the revision that was on screen when the
  choice was made, which is what lets a later read tell a choice that still
  means something from one made about words that have since changed.

  The candidates it beats stay `live`. They lose their tick and they cannot be
  ticked while this stands, but nothing about them has been decided: un-adopt
  this one and any of them can be chosen instead. Only publishing ends them, and
  only the ones that actually conflict with what was published.

  Refused while another conflicting candidate is adopted. Switching is
  `unadopt` then `adopt`, in that order, said out loud -- an adopt that silently
  displaced somebody's earlier choice would be a decision nobody made.
  """
  @impl true
  def adopt_proposal(%Document{} = document, proposal_id, base_revision_id, actor_id) do
    Repo.transact(fn repo ->
      locked_document =
        Document
        |> where([candidate], candidate.id == ^document.id)
        |> lock("FOR UPDATE")
        |> repo.one!()

      revision = latest_revision!(repo, locked_document, preload_blocks?: true)

      with :ok <- ensure_current(revision, base_revision_id),
           {:ok, proposal} <- fetch_proposal(repo, locked_document, proposal_id, lock?: true),
           :ok <- ensure_live(proposal),
           competitors = conflicting_live(repo, locked_document, proposal),
           :ok <- ensure_unclaimed(repo, locked_document, proposal, competitors, revision),
           {:ok, adopted} <- write_adoption(repo, proposal, revision.id),
           :ok <- unstage_all(repo, competitors, actor_id) do
        {:ok, describe(repo, locked_document, adopted, revision)}
      end
    end)
    |> unwrap_error()
  end

  @doc """
  Takes back a choice, leaving every candidate available again.

  It clears this proposal's adoption and does no more. It does not restore
  anything: not a rejection somebody made on purpose, not the ticks the losing
  candidates had before, and certainly not a published revision. Publishing is
  the point of no return, and the way back from it is a new proposal.

  This proposal's own tick is left where it is. It cannot be published while the
  argument it is in is open, which the review screen says; putting the tick back
  by hand is a person's business.
  """
  @impl true
  def unadopt_proposal(%Document{} = document, proposal_id) do
    Repo.transact(fn repo ->
      locked_document =
        Document
        |> where([candidate], candidate.id == ^document.id)
        |> lock("FOR UPDATE")
        |> repo.one!()

      revision = latest_revision!(repo, locked_document, preload_blocks?: true)

      with {:ok, proposal} <- fetch_proposal(repo, locked_document, proposal_id, lock?: true),
           :ok <- ensure_live(proposal),
           {:ok, updated} <- write_adoption(repo, proposal, nil) do
        {:ok, describe(repo, locked_document, updated, revision)}
      end
    end)
    |> unwrap_error()
  end

  @doc """
  Says no to a proposal.

  The one way a person turns something down, and it is deliberate rather than
  incidental: there is no withdraw, no delete and no undo beside it. A rejected
  proposal leaves the pending set and keeps everything else -- its text, its
  reason, and every message that ever cited it.

  Not the same thing as `superseded`, which is what happens to a proposal
  overtaken by a newer version of itself or by a competing change that published
  first. Nobody decided those.
  """
  @impl true
  def reject_proposal(%Document{} = document, proposal_id, actor_id, reason \\ nil) do
    Repo.transact(fn repo ->
      locked_document =
        Document
        |> where([candidate], candidate.id == ^document.id)
        |> lock("FOR UPDATE")
        |> repo.one!()

      revision = latest_revision!(repo, locked_document, preload_blocks?: true)

      with {:ok, proposal} <- fetch_proposal(repo, locked_document, proposal_id, lock?: true),
           :ok <- ensure_live(proposal),
           {:ok, rejected} <-
             decide_one(repo, proposal, :rejected, actor_id, DateTime.utc_now(), reason: reason) do
        {:ok, describe(repo, locked_document, rejected, revision)}
      end
    end)
    |> unwrap_error()
  end

  @doc """
  Lists the pairs of live proposals that cannot both stand.

  Pairs, not groups. Two rewrites of one paragraph are alternatives, and so are
  a rewrite and a deletion of it -- but the rewrite and a move of that same
  paragraph are not, and a group holding all three would ask somebody to give up
  an edit in order to keep a reordering. Nothing here is transitive: what a
  person is asked is always "this one or that one".
  """
  @impl true
  def contentions(%Document{} = document) do
    proposals = Repo |> live_proposals(document) |> Enum.sort_by(& &1.id)

    for left <- proposals,
        right <- proposals,
        left.id < right.id,
        reason = BlockProposal.conflict_reason(left, right) do
      %{
        reason: reason,
        proposal_ids: [left.id, right.id],
        scope: left.scope,
        block_id: left.block_id || right.block_id
      }
    end
  end

  @doc """
  Reads a document as one topic sees it: the latest revision with that topic's
  own applicable proposals standing in.

  A derived view and nothing else. It is not a branch, not a draft and not
  stored anywhere -- ask again a second later and it is computed again from
  whatever is current. Proposals of this topic's that cannot be applied are not
  quietly dropped: they come back named, with what stops them, because a topic
  that cannot see its own blocked work will write the same thing again.

  Other topics' proposals are counted, never shown. The point is not to let a
  topic reconcile the versions itself -- that is the person's decision -- but to
  stop it building on the assumption that it is alone in the block.
  """
  @impl true
  def blocks_for_conversation(%Document{} = document, conversation_id) do
    {:ok, view} = conversation_document_view(document, conversation_id)
    view.blocks
  end

  @doc """
  Reads the topic's derived blocks and the revision id they were computed from,
  atomically.

  Proposal writers and revision writers lock the document row before changing
  any of this. A shared lock therefore keeps both parts on one snapshot until
  the read completes, so a client cannot pair one revision's text with another
  revision's id.
  """
  @impl true
  def conversation_document_view(%Document{} = document, conversation_id) do
    Repo.transact(fn repo ->
      locked_document =
        Document
        |> where([candidate], candidate.id == ^document.id)
        |> lock("FOR SHARE")
        |> repo.one!()

      revision = latest_revision!(repo, locked_document, preload_blocks?: true)
      live = live_proposals(repo, locked_document)
      {mine, others} = Enum.split_with(live, &(&1.conversation_id == conversation_id))

      {:ok, working_view(repo, locked_document, revision, mine, others)}
    end)
    |> unwrap_error()
  end

  defp working_view(repo, document, revision, mine, others) do
    current = ProposalPlan.snapshot(revision)
    bases = base_snapshots(repo, document, mine)

    {applicable, blocked} =
      Enum.split_with(mine, fn proposal ->
        ProposalPlan.state(proposal, bases[proposal.base_revision_id], current) == :applicable
      end)

    {entries, unapplicable} = apply_working(repo, document, revision, applicable, current)

    %{
      revision_id: revision.id,
      blocks: overlay_blocks(entries, applicable, others),
      title: working_title(revision, applicable),
      unapplicable:
        Enum.map(blocked, fn proposal ->
          %{
            proposal_id: proposal.id,
            reason:
              state_reason(
                ProposalPlan.state(proposal, bases[proposal.base_revision_id], current)
              )
          }
        end) ++ unapplicable
    }
  end

  defp apply_working(repo, document, revision, applicable, current) do
    body = Enum.filter(applicable, &(&1.scope == :block))

    with {:ok, operations} <-
           ProposalPlan.operations(body, current, run_siblings(repo, document, body)),
         {:ok, entries} <-
           BlockOps.apply(revision.blocks |> Enum.sort_by(& &1.position), operations) do
      {entries, []}
    else
      # A set that cannot be applied as a whole is still a document the topic
      # has to be shown, so the revision stands and the reason is named.
      {:error, {code, details}} ->
        {plain_entries(revision), [Map.put(details, :reason, code)]}

      {:error, code, details} ->
        {plain_entries(revision), [Map.put(details, :reason, code)]}
    end
  end

  defp plain_entries(revision) do
    revision.blocks
    |> Enum.sort_by(& &1.position)
    |> Enum.map(&%{block_id: &1.block_id, actor_id: &1.actor_id, content: &1.content})
  end

  defp overlay_blocks(entries, mine, others) do
    authored = Map.new(mine, &{&1.block_id, &1})
    counted = Enum.frequencies_by(Enum.filter(others, &(&1.scope == :block)), & &1.block_id)

    entries
    |> Enum.with_index()
    |> Enum.map(fn {entry, position} ->
      proposal = Map.get(authored, entry.block_id)

      %{
        block_id: entry.block_id,
        position: position,
        content: entry.content,
        proposal_id: proposal && proposal.id,
        proposed?: proposal != nil,
        # A count, never the text. Reconciling versions is the human's decision;
        # this exists only so a topic knows it is not alone in the block.
        other_proposals: Map.get(counted, entry.block_id, 0)
      }
    end)
  end

  defp working_title(revision, applicable) do
    case Enum.find(applicable, &(&1.scope == :title)) do
      nil -> revision.title
      proposal -> proposal.content
    end
  end

  @doc """
  Turns the named proposals into a revision.

  Three things happen here and they happen together, in one transaction: the
  revision is written, the annotations named as settled are confirmed against
  it, and the proposals it applied become `accepted`. Publishing is the only
  natural moment for an annotation to be confirmed *with a revision* -- there is
  no other point at which somebody has both decided and changed the document --
  so a revision written without its confirmations, or confirmations pointing at
  a revision that failed to write, would both leave the record lying.

  ## What lands is what was asked for

  `proposal_ids` is required and is the whole of the selection. Nothing is
  inferred: not the ticks saved on the server, not an uncontested title, not a
  proposal the selected ones happen to depend on. A person who ticked something
  and then published something else published what they published, and a save
  that failed on its way to the server cannot quietly change what a request
  meant.

  `base_revision_id` is the ordinary check that the document has not moved under
  the screen. It is not a review version and not a rebase: when it is stale, the
  answer is to re-read and look at the new comparison, not to send the same
  selection again with a fresher id on it.

  ## What it invalidates

  Only what the applied proposals actually beat. A published change supersedes
  the live proposals that directly conflict with it -- the other rewrites of
  that paragraph, the deletion of it -- and nothing else. A proposal against a
  different paragraph is still true and stays live; the move of a paragraph
  whose text was just settled is still a different question. The set is worked
  out from the document as it stood before the write, so a candidate cannot slip
  through by the body having changed underneath.

  A selection every member of which has already been applied writes no revision.
  It says so -- `already_applied` -- rather than creating one identical to its
  parent, marking anybody as accepted, or superseding the candidates a publish
  that had actually happened would have beaten.
  """
  @impl true
  def commit_proposals(%Document{} = document, attrs) do
    Repo.transact(fn repo -> commit_within(repo, document, attrs) end)
    |> unwrap_error()
  end

  @doc """
  Publishes several documents at once, in one transaction.

  A discussion that changed a design usually changed more than one document,
  and half of that landing is the worst outcome available: the documents then
  disagree, and nothing records which half is the new answer. So the whole
  selection lands or none of it does.

  `commits` is a list of `{document, attrs}`, each `attrs` exactly what
  `commit_proposals/2` takes -- including its own `proposal_ids`, which are
  named there for the same reason they are named here. `actor_id` and
  `source_conversation_id` are per entry rather than shared, because they are
  already per entry there and a second way of saying them would be a second
  thing to keep in step.

  ## This is not a cross-document commit *record*

  Nothing new is stored and there is no batch id. `document_revisions` gains
  one row per document exactly as it would have, each carrying its own
  `source_conversation_id`, and "what did that discussion change?" stays a
  query. What this adds is atomicity, which is a property of the write rather
  than an entity.

  ## Order

  Documents are locked in id order, not in the order they were listed. Two
  batches touching the same two documents from different directions would
  otherwise each hold what the other is waiting for. Revisions come back in the
  order they were asked for, because that is the order the caller's screen is
  in and the lock order is nobody's business.

  The same document twice in one batch is refused. It is two ideas about what
  one commit is, and the second would silently be against a revision the first
  had just replaced.
  """
  @impl true
  def commit_many(commits) when is_list(commits) do
    with :ok <- ensure_distinct_documents(commits) do
      Repo.transact(fn repo -> commit_each(repo, commits) end)
      |> unwrap_error()
    end
  end

  defp ensure_distinct_documents(commits) do
    ids = Enum.map(commits, fn {document, _attrs} -> document.id end)

    case ids -- Enum.uniq(ids) do
      [] -> :ok
      [duplicate | _rest] -> {:error, :duplicate_document, %{document_id: duplicate}}
    end
  end

  # `commit_within/3` and not `commit_proposals/2`: the inner call must not open
  # a transaction of its own. A nested `Repo.transact` that returns an error
  # rolls the outer one back on its way out, and by the time this saw the result
  # there would be no transaction left to report which document failed in.
  defp commit_each(repo, commits) do
    commits
    |> Enum.with_index()
    |> Enum.sort_by(fn {{document, _attrs}, _asked} -> document.id end)
    |> Enum.reduce_while({:ok, []}, fn {{document, attrs}, asked}, {:ok, done} ->
      case commit_within(repo, document, attrs) do
        {:ok, result} -> {:cont, {:ok, [{asked, result} | done]}}
        {:error, reason} -> {:halt, {:error, name_document(reason, document)}}
      end
    end)
    |> case do
      {:ok, done} -> {:ok, done |> Enum.sort_by(&elem(&1, 0)) |> Enum.map(&elem(&1, 1))}
      {:error, _reason} = error -> error
    end
  end

  # "Which one failed" is the next question after any of these, and one commit
  # in a batch of four is not findable from a message about a stale revision.
  defp name_document({code, details}, %Document{} = document) when is_map(details),
    do: {code, Map.put(details, :document_id, document.id)}

  defp name_document(reason, _document), do: reason

  defp split_markdown(attrs, author_id) do
    case attr(attrs, :markdown, nil) do
      nil ->
        {:ok, put_blocks(attrs, [], author_id)}

      markdown when is_binary(markdown) ->
        case Markdown.split(markdown) do
          {:ok, contents} -> {:ok, put_blocks(attrs, contents, author_id)}
          {:error, _reason} -> {:error, invalid_markdown(attrs, author_id)}
        end

      _other ->
        {:error, invalid_markdown(attrs, author_id)}
    end
  end

  # A document with no project of its own goes to the default one. Resolved to
  # an id here rather than left to the changeset, so that everything downstream
  # sees a document that belongs somewhere.
  #
  # A missing default project is refused rather than quietly filed nowhere: it
  # means the reserved slug has been renamed or the setup task was never run,
  # and both are things to fix rather than to work around one document at a
  # time.
  defp put_default_project(attrs) do
    case attr(attrs, :project_id, nil) do
      nil ->
        case projects().get_default_project() do
          nil ->
            {:error, {:default_project_missing, %{slug: RintoPMO.Projects.default_slug()}}}

          project ->
            # Both key forms dropped first: `attrs` may carry either, and the
            # changeset stringifies keys, where two spellings of the same field
            # would collapse into whichever landed last.
            attrs
            |> Map.drop([:project_id, "project_id"])
            |> Map.put("project_id", project.id)
            |> then(&{:ok, &1})
        end

      _named ->
        {:ok, attrs}
    end
  end

  # Who a new document's blocks are credited to. The same rule proposals follow,
  # with the one difference that a document can be created outside any topic: a
  # person writing one directly is its author, and says so.
  defp document_author(attrs) do
    case attr(attrs, :conversation_id, nil) do
      conversation_id when is_binary(conversation_id) -> topic_author(conversation_id)
      _absent -> {:ok, attr(attrs, :actor_id, nil)}
    end
  end

  # Every block of a new document is credited to the one actor that wrote the
  # body. Per-block authorship only starts to differ once revisions land, and
  # those carry their own `actor_id` per operation.
  defp put_blocks(attrs, contents, actor_id) do
    blocks = Enum.map(contents, &%{actor_id: actor_id, content: &1})

    attrs
    |> Map.drop([:markdown, "markdown", :actor_id, "actor_id", :blocks, "blocks"])
    |> Map.put(:blocks, blocks)
  end

  defp invalid_markdown(attrs, author_id) do
    %Document{}
    |> Document.creation_changeset(put_blocks(attrs, [], author_id))
    |> Changeset.add_error(:markdown, "is invalid")
  end

  defp filter_documents(query, filter) do
    Enum.reduce(filter, query, fn
      {:project, :unassigned}, query ->
        where(query, [document], is_nil(document.project_id))

      {:project, project_id}, query ->
        where(query, [document], document.project_id == ^project_id)

      {:status, status}, query ->
        where(query, [document], document.status == ^status)

      {_other, _value}, query ->
        query
    end)
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
            supersede(repo, parent)

            changeset
            |> put_block_snapshots(block_entries, parent.blocks)
            |> repo.insert()
            |> index_revision(repo, parent)

          {:error, code, details} ->
            {:error, {code, details}}
        end
    end
  end

  # Before the insert, not after: `document_revisions_one_latest_per_document`
  # permits one current revision per document at every moment rather than
  # merely at commit, and a partial unique index cannot be deferred. Both
  # statements are in the caller's transaction, so an insert that fails takes
  # this back with it and the parent is the latest again.
  defp supersede(repo, %DocumentRevision{id: id}) do
    DocumentRevision
    |> where([revision], revision.id == ^id)
    |> repo.update_all(set: [is_latest: false])
  end

  # In the same transaction as the revision, because an index written afterwards
  # has a window where the body says one thing and "who points at this?" says
  # another. See `RintoPMO.Links`.
  defp index_revision({:ok, %DocumentRevision{} = revision}, repo, parent) do
    Links.sync_document(repo, revision)
    retire_embeddings(repo, parent)
    {:ok, revision}
  end

  defp index_revision(result, _repo, _parent), do: result

  # Whatever the new revision needed has been carried onto its own rows, so the
  # superseded ones are holding four kilobytes apiece to answer a question
  # nobody asks: history is not searched. Clearing them also leaves exactly one
  # snapshot of each block carrying a vector, which is what lets the embedding
  # worker recognise its own backlog without qualifying every row.
  defp retire_embeddings(repo, %DocumentRevision{id: id}) do
    DocumentBlock
    |> where([block], block.revision_id == ^id)
    |> where([block], not is_nil(block.embedding))
    |> repo.update_all(set: [embedding: nil])
  end

  @doc false
  # Every block of a revision is written as a new row, including the ones nobody
  # touched -- so a vector would be lost on all of them each time one changed,
  # and nineteen blocks out of twenty would be re-embedded for nothing.
  #
  # They are not lost, because the previous revision's blocks are already in
  # hand here: `BlockOps.apply/2` was just run against them. A block whose
  # content is byte-for-byte what it was carries its vector forward; one that
  # changed, or that did not exist before, starts null and the embedding worker
  # picks it up.
  #
  # **The invalidation is structural.** Nothing compares anything at read time
  # and nothing has to remember to clear a column, because a new row simply has
  # no vector unless the text it holds is the text the vector was made from.
  defp put_block_snapshots(changeset, block_entries, previous_blocks) do
    previous = Map.new(previous_blocks, &{&1.block_id, &1})

    block_changesets =
      block_entries
      |> Enum.with_index()
      |> Enum.map(fn {entry, position} ->
        %DocumentBlock{
          block_id: entry.block_id,
          position: position,
          embedding: carried_forward(previous[entry.block_id], entry.content)
        }
        |> DocumentBlock.changeset(%{actor_id: entry.actor_id, content: entry.content})
      end)

    Changeset.put_assoc(changeset, :blocks, block_changesets)
  end

  defp carried_forward(%DocumentBlock{content: content, embedding: embedding}, content),
    do: embedding

  defp carried_forward(_absent_or_changed, _content), do: nil

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
      {:id, id}, query ->
        where(query, [proposal], proposal.id == ^id)

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

  defp live_proposals(repo, %Document{} = document) do
    document
    |> Ecto.assoc(:proposals)
    |> where([proposal], proposal.status == :live)
    |> repo.all()
  end

  defp fetch_proposal(repo, %Document{} = document, proposal_id, options) do
    query = document |> Ecto.assoc(:proposals) |> where([proposal], proposal.id == ^proposal_id)
    query = if Keyword.get(options, :lock?, false), do: lock(query, "FOR UPDATE"), else: query

    case repo.one(query) do
      nil -> {:error, {:proposal_not_found, %{proposal_id: proposal_id}}}
      proposal -> {:ok, proposal}
    end
  end

  defp ensure_live(%BlockProposal{status: :live}), do: :ok

  defp ensure_live(%BlockProposal{} = proposal),
    do: {:error, {:proposal_not_live, %{proposal_id: proposal.id, status: proposal.status}}}

  defp ensure_current(%DocumentRevision{id: id}, id), do: :ok

  defp ensure_current(%DocumentRevision{id: id}, _other),
    do: {:error, {:stale_document, %{current_revision_id: id}}}

  # Conflict is a relation, so the answer for a whole set is the pairs it
  # contains rather than a partition of it. Built once and read many times: a
  # review screen asks this of every row it draws.
  defp conflict_map(proposals) do
    Map.new(proposals, fn proposal ->
      {proposal.id,
       for(other <- proposals, BlockProposal.conflict_reason(proposal, other), do: other.id)}
    end)
  end

  defp conflicting_live(repo, document, %BlockProposal{} = proposal) do
    repo
    |> live_proposals(document)
    |> Enum.filter(&BlockProposal.conflict_reason(proposal, &1))
  end

  # Somebody has already chosen among these candidates, and that choice still
  # refers to what it was made about. Taking it away silently is what `unadopt`
  # exists to make somebody do out loud.
  defp ensure_unclaimed(repo, document, proposal, competitors, revision) do
    snapshots = snapshots(repo, document, adoption_revision_ids(competitors))
    current = ProposalPlan.snapshot(revision)

    case Enum.find(competitors, &adoption_valid?(&1, current, revision, snapshots)) do
      nil ->
        :ok

      claimed ->
        {:error, {:already_adopted, %{proposal_id: proposal.id, adopted_proposal_id: claimed.id}}}
    end
  end

  defp write_adoption(repo, %BlockProposal{} = proposal, revision_id) do
    proposal
    |> BlockProposal.adoption_changeset(revision_id)
    |> repo.update()
  end

  # The candidates a choice just beat lose their tick and keep their life. They
  # are not decided: un-adopting brings all of them back into play, and only a
  # publish ends any of them.
  defp unstage_all(repo, proposals, _actor_id) do
    proposals
    |> Enum.filter(& &1.staged)
    |> Enum.reduce_while(:ok, fn proposal, :ok ->
      case proposal |> BlockProposal.staged_changeset(false) |> repo.update() do
        {:ok, _proposal} -> {:cont, :ok}
        {:error, changeset} -> {:halt, {:error, changeset}}
      end
    end)
  end

  defp describe(repo, document, %BlockProposal{} = proposal, revision) do
    [detail] = describe_proposals(repo, document, [proposal], revision)
    detail
  end

  defp describe_proposals(repo, document, proposals, revision) do
    current = ProposalPlan.snapshot(revision)
    conflicts = repo |> live_proposals(document) |> conflict_map()

    snapshots =
      snapshots(
        repo,
        document,
        Enum.map(proposals, & &1.base_revision_id) ++ adoption_revision_ids(proposals)
      )

    Enum.map(proposals, fn proposal ->
      state = ProposalPlan.state(proposal, snapshots[proposal.base_revision_id], current)
      adopted = adoption_valid?(proposal, current, revision, snapshots)

      %{
        proposal: proposal,
        state: state_name(state),
        reason: state_reason(state),
        adopted: adopted,
        # Told apart from "never adopted" because they call for different
        # things: one is an argument nobody has settled, the other is a
        # settlement about words that have since changed.
        adoption_stale: not adopted and not is_nil(proposal.adopted_revision_id),
        conflicting_proposal_ids: Map.get(conflicts, proposal.id, []),
        current_revision_id: revision.id
      }
    end)
  end

  defp adoption_revision_ids(proposals) do
    for %BlockProposal{adopted_revision_id: id} <- proposals, not is_nil(id), do: id
  end

  # An adoption is worth something only while what was on screen when it was
  # made still says what it said. Compared at the grain of what this proposal
  # actually argues about, so an edit three sections away does not send somebody
  # back to a decision they already took.
  defp adoption_valid?(%BlockProposal{adopted_revision_id: nil}, _current, _revision, _snapshots),
    do: false

  defp adoption_valid?(%BlockProposal{adopted_revision_id: id}, _current, %{id: id}, _snapshots),
    do: true

  defp adoption_valid?(%BlockProposal{} = proposal, current, _revision, snapshots) do
    case Map.get(snapshots, proposal.adopted_revision_id) do
      nil ->
        false

      adopted ->
        ProposalPlan.relevance(proposal, adopted) == ProposalPlan.relevance(proposal, current)
    end
  end

  defp snapshots(repo, %Document{} = document, revision_ids) do
    case revision_ids |> Enum.reject(&is_nil/1) |> Enum.uniq() do
      [] ->
        %{}

      ids ->
        document
        |> Ecto.assoc(:revisions)
        |> where([revision], revision.id in ^ids)
        |> repo.all()
        |> repo.preload(:blocks)
        |> Map.new(&{&1.id, ProposalPlan.snapshot(&1)})
    end
  end

  defp state_name(:applicable), do: :applicable
  defp state_name(:already_applied), do: :already_applied
  defp state_name({name, _reason}), do: name

  defp state_reason({_name, reason}), do: reason
  defp state_reason(_state), do: nil

  # Every proposal that belongs to the same written sequence as one of these,
  # whatever has since become of it. A run's order is only recoverable from its
  # members, and the members a publish leaves out are exactly the ones it has to
  # know about.
  defp run_siblings(repo, %Document{} = document, proposals) do
    case for %BlockProposal{run_id: id} <- proposals, not is_nil(id), do: id do
      [] ->
        %{}

      run_ids ->
        document
        |> Ecto.assoc(:proposals)
        |> where([proposal], proposal.run_id in ^run_ids)
        |> repo.all()
        |> Enum.group_by(& &1.run_id)
    end
  end

  # The revision whose text the caller actually read. Checked against this
  # document rather than trusted, and never filled in here: a server that
  # stamped the latest revision onto a body written against an older one would
  # turn every stale rewrite into a silent revert.
  defp fetch_base_revision(repo, %Document{} = document, attrs) do
    case attr(attrs, :base_revision_id, nil) do
      nil ->
        {:error, {:base_revision_required, %{}}}

      value ->
        with {:ok, id} <- cast_revision_id(value) do
          read_revision(repo, document, id, value)
        end
    end
  end

  defp read_revision(repo, document, id, named) do
    document
    |> Ecto.assoc(:revisions)
    |> where([revision], revision.id == ^id)
    |> repo.one()
    |> case do
      nil -> {:error, {:unknown_revision, %{revision_id: named}}}
      revision -> {:ok, repo.preload(revision, :blocks)}
    end
  end

  defp cast_revision_id(value) do
    case UUIDv7.cast(value) do
      {:ok, id} -> {:ok, id}
      :error -> {:error, {:unknown_revision, %{revision_id: value}}}
    end
  end

  # What a propose call leaves behind, and what it writes.
  #
  # An intent this topic already has standing keeps the row it has, id and all,
  # so re-running a generation that reached the same answer does not orphan
  # every message that cited the first one. Anything the call replaces is
  # superseded before the new rows go in, both because the slot is unique and
  # because the old one really has been overtaken.
  defp reconcile_proposals(repo, document, base, actor_id, attrs, wanted, replaces) do
    decided_at = DateTime.utc_now()
    conversation_id = attr(attrs, :conversation_id, nil)
    existing = replaceable_proposals(repo, document, conversation_id, replaces)
    by_intent = Map.new(existing, &{intent_key(&1), &1})

    reused = for intent <- wanted, proposal = by_intent[intent_key(intent)], do: proposal
    obsolete = existing -- reused

    with :ok <- decide_each(repo, obsolete, :superseded, actor_id, decided_at) do
      case write_intents(repo, document, base, actor_id, attrs, wanted, by_intent, obsolete) do
        {:ok, proposals} -> {:ok, proposals, Enum.map(obsolete, & &1.id)}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp write_intents(repo, document, base, actor_id, attrs, wanted, by_intent, obsolete) do
    replaced = Map.new(obsolete, &{slot_key(&1), &1})

    wanted
    |> Enum.reduce_while({:ok, []}, fn intent, {:ok, written} ->
      case reuse_or_write(repo, document, base, actor_id, attrs, intent, by_intent, replaced) do
        {:ok, proposal} -> {:cont, {:ok, [proposal | written]}}
        {:error, changeset} -> {:halt, {:error, changeset}}
      end
    end)
    |> case do
      {:ok, written} -> {:ok, Enum.reverse(written)}
      error -> error
    end
  end

  defp reuse_or_write(repo, document, base, actor_id, attrs, intent, by_intent, replaced) do
    case Map.fetch(by_intent, intent_key(intent)) do
      {:ok, proposal} -> {:ok, proposal}
      :error -> insert_intent(repo, document, base, actor_id, attrs, intent, replaced)
    end
  end

  defp insert_intent(repo, document, base, actor_id, attrs, intent, replaced) do
    intent
    |> Map.merge(%{
      document_id: document.id,
      conversation_id: attr(attrs, :conversation_id, nil),
      actor_id: actor_id,
      base_revision_id: base.id,
      change_summary: attr(attrs, :change_summary, nil),
      supersedes_id: replaced |> Map.get(slot_key(intent)) |> then(&(&1 && &1.id))
    })
    |> BlockProposal.changeset()
    |> repo.insert()
  end

  defp replaceable_proposals(repo, document, conversation_id, {:scope, scope}) do
    document
    |> Ecto.assoc(:proposals)
    |> where([proposal], proposal.status == :live)
    |> where([proposal], proposal.conversation_id == ^conversation_id)
    |> where([proposal], proposal.scope == ^scope)
    |> lock("FOR UPDATE")
    |> repo.all()
  end

  defp replaceable_proposals(repo, document, conversation_id, {:slots, slots}) do
    block_ids = Enum.map(slots, &elem(&1, 0))

    document
    |> Ecto.assoc(:proposals)
    |> where([proposal], proposal.status == :live)
    |> where([proposal], proposal.conversation_id == ^conversation_id)
    |> where([proposal], proposal.scope == :block and proposal.block_id in ^block_ids)
    |> lock("FOR UPDATE")
    |> repo.all()
    |> Enum.filter(&({&1.block_id, &1.operation} in slots))
  end

  # What makes two proposals the same modification. Position metadata is not in
  # it: a run is how insertions were written down, not what they say.
  defp intent_key(%BlockProposal{} = proposal) do
    {proposal.scope, proposal.operation, proposal.block_id, proposal.after_block_id,
     proposal.content}
  end

  defp intent_key(intent) when is_map(intent) do
    {intent.scope, intent.operation, Map.get(intent, :block_id), Map.get(intent, :after_block_id),
     Map.get(intent, :content)}
  end

  # The unique slot a topic holds: one rewrite of a block, one move of it, one
  # title. What a new row in that slot replaces is the row that was in it.
  defp slot_key(%BlockProposal{scope: :title}), do: {:title, :update}
  defp slot_key(%BlockProposal{} = proposal), do: {proposal.block_id, proposal.operation}

  defp slot_key(%{scope: :title}), do: {:title, :update}
  defp slot_key(intent) when is_map(intent), do: {Map.get(intent, :block_id), intent.operation}

  defp proposed_result(repo, document, proposals, superseded) do
    conflicts = repo |> live_proposals(document) |> conflict_map()

    %{
      proposals: proposals,
      summary: proposal_summary(proposals),
      superseded: superseded,
      contended: contended_result(proposals, conflicts)
    }
  end

  defp contended_result(proposals, conflicts) do
    for proposal <- proposals,
        competitors = Map.get(conflicts, proposal.id, []),
        competitors != [] do
      %{proposal_id: proposal.id, conflicting_proposal_ids: competitors}
    end
  end

  defp proposal_summary(proposals) do
    Enum.reduce(proposals, %{changed: 0, added: 0, removed: 0, moved: 0}, fn proposal, summary ->
      case proposal.operation do
        :update -> Map.update!(summary, :changed, &(&1 + 1))
        :insert -> Map.update!(summary, :added, &(&1 + 1))
        :delete -> Map.update!(summary, :removed, &(&1 + 1))
        :move -> Map.update!(summary, :moved, &(&1 + 1))
      end
    end)
  end

  # Who a proposal is by. Not a parameter: see "Who wrote a proposal is not a
  # caller's to say" above.
  defp proposal_author(attrs) do
    case attr(attrs, :conversation_id, nil) do
      conversation_id when is_binary(conversation_id) ->
        topic_author(conversation_id)

      _absent ->
        # A proposal without a topic has nobody to be by, and the changeset says
        # so in the caller's own vocabulary.
        {:ok, nil}
    end
  end

  defp topic_author(conversation_id) do
    with {:ok, conversation} <- fetch_conversation(conversation_id) do
      author_of(conversation)
    end
  end

  defp fetch_conversation(conversation_id) do
    {:ok, conversations().get_conversation!(conversation_id)}
  rescue
    Ecto.NoResultsError ->
      {:error, {:conversation_not_found, %{conversation_id: conversation_id}}}
  end

  # Everything an AI writes is signed by the one actor that stands in for "a
  # model wrote this" -- see `RintoPMO.Actors.Actor`. Not by the topic's
  # persona, even where there is one.
  #
  # The distinction anything downstream actually reads is model-or-person, and
  # that is the whole of what this row says. Which persona was configured on
  # the topic at the time is a different question, it is answered by the
  # conversation itself, and resolving it here bought a branch per topic mode
  # plus a refusal for a topic still choosing its assistant -- a write path
  # failing on a decision nobody had made yet.
  defp author_of(%{id: conversation_id}) do
    case actors().get_default_assistant() do
      nil -> {:error, {:default_assistant_missing, %{conversation_id: conversation_id}}}
      actor -> {:ok, actor.id}
    end
  end

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
        {:error, {:invalid_markdown, %{reason: "content is required"}}}

      _not_a_string ->
        {:error, {:invalid_markdown, %{reason: "content must be a string"}}}
    end
  end

  # Against the revision the topic read, not against the latest one. Compiling
  # against a revision nobody looked at would attribute somebody else's
  # paragraphs to this rewrite and then quietly revert them.
  defp compile_operations(%DocumentRevision{} = base, contents, actor_id) do
    case BlockDiff.compile(ordered_blocks(base), contents, actor_id) do
      [] -> {:error, {:no_change_proposed, %{}}}
      operations -> {:ok, operations}
    end
  end

  defp ordered_blocks(%DocumentRevision{blocks: blocks}) when is_list(blocks) do
    Enum.sort_by(blocks, & &1.position)
  end

  defp base_snapshots(repo, document, proposals) do
    snapshots(repo, document, Enum.map(proposals, & &1.base_revision_id))
  end

  defp decide_each(repo, proposals, status, actor_id, decided_at, options \\ []) do
    Enum.reduce_while(proposals, :ok, fn proposal, :ok ->
      case decide_one(repo, proposal, status, actor_id, decided_at, options) do
        {:ok, _proposal} -> {:cont, :ok}
        {:error, changeset} -> {:halt, {:error, changeset}}
      end
    end)
  end

  defp decide_one(repo, proposal, status, actor_id, decided_at, options) do
    proposal
    |> BlockProposal.decision_changeset(status, actor_id, decided_at, options)
    |> repo.update()
  end

  # Publishing

  defp commit_within(repo, %Document{} = document, attrs) do
    locked_document =
      Document
      |> where([candidate], candidate.id == ^document.id)
      |> lock("FOR UPDATE")
      |> repo.one!()

    parent = latest_revision!(repo, locked_document, preload_blocks?: true)
    current = ProposalPlan.snapshot(parent)

    with :ok <- ensure_current(parent, attr(attrs, :base_revision_id, nil)),
         {:ok, ids} <- selected_ids(attrs),
         {:ok, selected} <- fetch_selected(repo, locked_document, ids),
         :ok <- ensure_all_live(selected),
         :ok <- ensure_selection_compatible(selected),
         {:ok, applying, satisfied} <-
           partition_selection(repo, locked_document, selected, parent, current) do
      publish(repo, locked_document, parent, current, attrs, applying, satisfied)
    end
  end

  defp selected_ids(attrs) do
    case attr(attrs, :proposal_ids, nil) do
      ids when is_list(ids) and ids != [] ->
        case ids -- Enum.uniq(ids) do
          [] -> {:ok, ids}
          [duplicate | _rest] -> {:error, {:duplicate_proposal, %{proposal_id: duplicate}}}
        end

      [] ->
        {:error, {:nothing_to_commit, %{}}}

      nil ->
        {:error, {:nothing_to_commit, %{}}}

      _other ->
        {:error, {:validation_error, %{proposal_ids: ["must be an array"]}}}
    end
  end

  # Scoped to this document, so an id from elsewhere is missing rather than
  # borrowed. The order asked for is kept: it is the order a person read them
  # in, and nothing downstream depends on it being anything else.
  defp fetch_selected(repo, document, ids) do
    found =
      document
      |> Ecto.assoc(:proposals)
      |> where([proposal], proposal.id in ^ids)
      |> lock("FOR UPDATE")
      |> repo.all()
      |> Map.new(&{&1.id, &1})

    case Enum.reject(ids, &Map.has_key?(found, &1)) do
      [] -> {:ok, Enum.map(ids, &Map.fetch!(found, &1))}
      missing -> {:error, {:proposal_not_found, %{proposal_ids: missing}}}
    end
  end

  defp ensure_all_live(selected) do
    case Enum.reject(selected, &(&1.status == :live)) do
      [] ->
        :ok

      settled ->
        {:error,
         {:proposal_not_live,
          %{proposal_ids: Enum.map(settled, & &1.id), statuses: Enum.map(settled, & &1.status)}}}
    end
  end

  # Two things in one publish that cannot both be true. Refused rather than
  # ordered: picking one of them is exactly the decision this system leaves to a
  # person, and doing it here would do it invisibly.
  defp ensure_selection_compatible(selected) do
    conflicts =
      for left <- selected,
          right <- selected,
          left.id < right.id,
          reason = BlockProposal.conflict_reason(left, right) do
        %{proposal_ids: [left.id, right.id], reason: reason}
      end

    if conflicts == [] do
      :ok
    else
      {:error, {:conflicting_selection, %{conflicts: conflicts}}}
    end
  end

  # What each selected proposal still means against the document as it stands.
  # A publish either takes the whole selection or refuses: applying the legal
  # half and reporting success would leave a person believing they had published
  # something they had not.
  defp partition_selection(repo, document, selected, parent, current) do
    bases = base_snapshots(repo, document, selected)
    adopted = snapshots(repo, document, adoption_revision_ids(selected))
    snapshots = Map.merge(bases, adopted)

    Enum.reduce_while(selected, {:ok, [], []}, fn proposal, {:ok, applying, satisfied} ->
      case classify(proposal, snapshots, current, parent) do
        :apply -> {:cont, {:ok, [proposal | applying], satisfied}}
        :satisfied -> {:cont, {:ok, applying, [proposal | satisfied]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, applying, satisfied} -> {:ok, Enum.reverse(applying), Enum.reverse(satisfied)}
      error -> error
    end
  end

  defp classify(proposal, snapshots, current, parent) do
    case ProposalPlan.state(proposal, snapshots[proposal.base_revision_id], current) do
      :applicable ->
        :apply

      :already_applied ->
        :satisfied

      {:needs_confirmation, reason} ->
        if adoption_valid?(proposal, current, parent, snapshots) do
          :apply
        else
          {:error, {:needs_reconfirmation, %{proposal_id: proposal.id, reason: reason}}}
        end

      {:not_applicable, reason} ->
        {:error, {:proposal_not_applicable, %{proposal_id: proposal.id, reason: reason}}}
    end
  end

  # Nothing left to do, and saying so rather than writing a revision identical
  # to its parent. Nobody is accepted -- no publish applied these -- and no
  # competing candidate is superseded, because nothing beat it. What does happen
  # is that the ticks come off: they are waiting for something that has already
  # happened.
  defp publish(repo, document, parent, _current, _attrs, [], satisfied) do
    with :ok <- clear_marks(repo, satisfied) do
      {:ok,
       %{
         result: :already_applied,
         revision: nil,
         current_revision_id: parent.id,
         document_id: document.id,
         accepted: [],
         superseded: [],
         already_applied: Enum.map(satisfied, & &1.id)
       }}
    end
  end

  defp publish(repo, document, parent, current, attrs, applying, satisfied) do
    actor_id = attr(attrs, :actor_id, nil)
    body = Enum.filter(applying, &(&1.scope == :block))
    # Worked out before the write, against the document the selection was
    # judged on. Afterwards the body has moved and a candidate that lost would
    # no longer look like one.
    beaten = beaten_by(repo, document, applying)

    with {:ok, operations} <-
           ProposalPlan.operations(body, current, run_siblings(repo, document, body)),
         revision_attrs = publication_attrs(attrs, applying, operations),
         {:ok, revision} <- insert_revision(repo, document, parent, revision_attrs),
         :ok <- accept_all(repo, applying, actor_id, revision.id),
         :ok <- decide_each(repo, beaten, :superseded, actor_id, DateTime.utc_now()),
         :ok <- clear_marks(repo, satisfied),
         :ok <- confirm_annotations(document, revision, attrs) do
      {:ok,
       %{
         result: :published,
         revision: revision,
         current_revision_id: revision.id,
         document_id: document.id,
         accepted: Enum.map(applying, & &1.id),
         superseded: Enum.map(beaten, & &1.id),
         already_applied: Enum.map(satisfied, & &1.id)
       }}
    end
  end

  # Only what the published changes actually beat: the other answers to the
  # questions they answered. A proposal about a different paragraph is still
  # true, and a move of a paragraph whose text was just settled is still a
  # different question.
  defp beaten_by(repo, document, applying) do
    published = MapSet.new(applying, & &1.id)

    repo
    |> live_proposals(document)
    |> Enum.reject(&MapSet.member?(published, &1.id))
    |> Enum.filter(fn candidate ->
      Enum.any?(applying, &BlockProposal.conflict_reason(&1, candidate))
    end)
  end

  defp publication_attrs(attrs, applying, operations) do
    %{
      block_ops: operations,
      base_revision_id: attr(attrs, :base_revision_id, nil),
      source_conversation_id: attr(attrs, :source_conversation_id, nil)
    }
    |> maybe_put(:title, published_title(applying))
    |> maybe_put(:change_summary, proposal_change_summary(attrs, applying))
  end

  # A title changes when a title proposal was published, and never otherwise.
  # There is no field on the request that means "and also call it this": typing
  # a title is writing a revision, which is a different thing a person does
  # somewhere else.
  defp published_title(applying) do
    case Enum.find(applying, &(&1.scope == :title)) do
      nil -> nil
      proposal -> proposal.content
    end
  end

  defp proposal_change_summary(attrs, proposals) do
    case attr(attrs, :change_summary, nil) do
      summary when is_binary(summary) and summary != "" ->
        summary

      _absent ->
        case proposals
             |> Enum.map(& &1.change_summary)
             |> Enum.filter(&(is_binary(&1) and &1 != ""))
             |> Enum.uniq() do
          [summary] -> summary
          _none_or_ambiguous -> nil
        end
    end
  end

  # `title` is absent rather than nil when unset, because the revision
  # changeset reads its absence as "keep the parent's".
  defp maybe_put(attrs, _key, nil), do: attrs
  defp maybe_put(attrs, key, value), do: Map.put(attrs, key, value)

  defp accept_all(repo, applying, actor_id, revision_id) do
    decide_each(repo, applying, :accepted, actor_id, DateTime.utc_now(),
      accepted_revision_id: revision_id
    )
  end

  # A proposal that got what it wanted without this publish applying it. It is
  # still live and still readable; what it stops being is something waiting to
  # be taken.
  defp clear_marks(repo, proposals) do
    proposals
    |> Enum.filter(&(&1.staged or not is_nil(&1.adopted_revision_id)))
    |> Enum.reduce_while(:ok, fn proposal, :ok ->
      changeset =
        proposal
        |> BlockProposal.staged_changeset(false)
        |> Ecto.Changeset.put_change(:adopted_revision_id, nil)

      case repo.update(changeset) do
        {:ok, _proposal} -> {:cont, :ok}
        {:error, changeset} -> {:halt, {:error, changeset}}
      end
    end)
  end

  defp confirm_annotations(document, revision, attrs) do
    attrs
    |> attr(:confirm_annotation_ids, [])
    |> List.wrap()
    |> Enum.reduce_while(:ok, fn annotation_id, :ok ->
      case confirm_annotation(document, revision, annotation_id) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  # Scoped to the document, so an annotation from elsewhere cannot be confirmed
  # by a revision that could not have touched it. An annotation always belongs
  # to a document and the revision confirming it is in that same document, so
  # the two line up without anything having to check.
  #
  # This is the one place a confirmation carries a revision without a person
  # naming it separately: they named the annotation in the same breath as the
  # commit, which is exactly the claim "this change is what settled that".
  defp confirm_annotation(document, revision, annotation_id) do
    context = annotations()
    annotation = context.get_annotation!(document, annotation_id)

    case context.confirm_annotation(annotation, %{confirmed_by_revision_id: revision.id}) do
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

  # Already in the shape `RintoPMOWeb.FallbackController` renders -- a refusal
  # raised before this context wrapped anything, such as a body pointing at
  # something that is not there.
  defp unwrap_error({:error, code, details}), do: {:error, code, details}

  defp annotations, do: Utils.module(:annotations)

  # Only ever asked one thing: the stand-in a plain chat's writing is signed
  # with, because that topic has no assistant of its own to name.
  defp actors, do: Utils.module(:actors)

  # The one thing this context asks of another: how a topic's assistant is
  # configured, so a proposal can be attributed without a caller saying.
  defp conversations, do: Utils.module(:conversations)

  # And which project a document with none of its own belongs to.
  defp projects, do: Utils.module(:projects)
end
