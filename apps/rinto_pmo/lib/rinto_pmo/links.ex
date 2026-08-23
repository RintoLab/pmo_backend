defmodule RintoPMO.Links do
  @moduledoc """
  Keeps the `links` index following the bodies it was read out of.

  Every function here takes a `repo` and is called **inside the transaction that
  wrote the body**. That is not a style choice: an index written in a second
  transaction has a window where the text says one thing and the index says
  another, and every reader in that window is wrong.

  For the same reason none of the write side goes through a behaviour. Only
  reads are injected (`RintoPMO.Links.Behaviour`). Mocking `sync/5` would let a
  document test pass while the index it was supposed to maintain went unwritten
  -- the test would be asserting the mock, not the system.

  ## Following a body

  There is no diffing. A body that changed has its rows deleted and rewritten
  from the new text, which is both simpler and the only version that cannot
  drift: whatever went wrong last time is gone the next time the body is saved.

  ## An unparseable body indexes as nothing

  `RintoPMO.References.extract/1` can fail, and when it does this records no
  links rather than failing the write. The index is not the truth (see
  `RintoPMO.Links.Link`), and refusing to save a task because its description
  confused a Markdown parser would trade something that matters for something
  that does not.
  """

  use RintoPMO, :context

  alias RintoPMO.Annotations.Annotation
  alias RintoPMO.Annotations.AnnotationReply
  alias RintoPMO.Conversations.Conversation
  alias RintoPMO.Conversations.Message
  alias RintoPMO.Documents.BlockProposal
  alias RintoPMO.Documents.Document
  alias RintoPMO.Documents.DocumentBlock
  alias RintoPMO.Documents.DocumentRevision
  alias RintoPMO.Links.Link
  alias RintoPMO.References
  alias RintoPMO.Tasks.Task

  @typedoc """
  One reference pointing at the thing that was asked about.

  `source` names where the text lives; `label` is what that text called the
  target, which is what a reader is shown when the target itself is gone.
  """
  @type backlink :: %{
          source_type: String.t(),
          source_id: UUIDv7.t(),
          document_id: UUIDv7.t() | nil,
          document_title: String.t() | nil,
          title: String.t() | nil,
          excerpt: String.t() | nil,
          label: String.t(),
          position: non_neg_integer(),
          archived: boolean()
        }

  defmodule Behaviour do
    @moduledoc false

    @callback backlinks(RintoPMO.References.Reference.t()) :: [RintoPMO.Links.backlink()]
  end

  @behaviour Behaviour

  @doc """
  Everything whose text points at `reference`, newest first.

  **Only the read side is injected.** `sync/5` and friends are part of writing
  correctly, and a mock in their place would let a document test pass over an
  index that was never written.

  A source whose own target has since been deleted still answers here. That is
  the point of keeping the row: the reference was really made, and reporting it
  as broken is more useful than pretending it never happened.
  """
  @impl true
  def backlinks(%References.Reference{} = reference) do
    Link
    |> where([link], link.target_type == ^reference.type)
    |> by_key(reference)
    |> order_by([link], desc: link.id)
    |> Repo.all()
    |> describe()
  end

  defp by_key(query, reference) do
    case References.id(reference) do
      nil -> where(query, [link], link.target_slug == ^reference.key)
      id -> where(query, [link], link.target_id == ^id)
    end
  end

  @doc """
  Rewrites the index for one piece of text.

  `opts` may carry `:document_id`, the document the text lives in, which is what
  scopes a later document-wide cleanup.
  """
  @spec sync(Ecto.Repo.t(), String.t(), UUIDv7.t(), String.t() | nil, keyword()) :: :ok
  def sync(repo, source_type, source_id, content, opts \\ []) do
    purge(repo, source_type, source_id)
    insert_all(repo, source_type, source_id, Keyword.get(opts, :document_id), content)
    :ok
  end

  @doc """
  Rewrites the index for every block of a document's newest revision.

  Deletes by document rather than by block, because a revision can drop a block
  entirely and a per-block rewrite would leave the dropped one's references
  behind. `revision.blocks` must be loaded.
  """
  @spec sync_document(Ecto.Repo.t(), DocumentRevision.t()) :: :ok
  def sync_document(repo, %DocumentRevision{blocks: blocks} = revision) when is_list(blocks) do
    Link
    |> where([link], link.source_type == "document_block")
    |> where([link], link.source_document_id == ^revision.document_id)
    |> repo.delete_all()

    Enum.each(blocks, fn block ->
      insert_all(repo, "document_block", block.block_id, revision.document_id, block.content)
    end)

    :ok
  end

  @doc """
  Drops everything one source had written.

  Called where a source is really deleted. Missing one costs a stale row that
  `mix rinto.links.rebuild` clears, which is the point of the index being
  rebuildable rather than a reason to be careless.
  """
  @spec purge(Ecto.Repo.t(), String.t(), UUIDv7.t()) :: :ok
  def purge(repo, source_type, source_id) do
    Link
    |> where([link], link.source_type == ^source_type and link.source_id == ^source_id)
    |> repo.delete_all()

    :ok
  end

  @doc """
  Empties the index and reads it back out of every body in the system.

  This is what makes "the index is not the truth" checkable rather than merely
  asserted. It is also the backfill for bodies written before the index existed,
  and the repair for any sync a future write path forgets.

  One transaction, so a run that dies leaves the previous index rather than half
  of a new one. That does mean a long transaction on a large corpus, which is
  accepted: this is a tool a person runs, not something on a request path.

  Returns a tally per source type.
  """
  @spec rebuild(Ecto.Repo.t()) :: %{String.t() => non_neg_integer()}
  def rebuild(repo \\ Repo) do
    repo.transact(fn repo ->
      repo.delete_all(Link)

      {:ok,
       %{
         "document_block" => rebuild_blocks(repo),
         "annotation" => rebuild_annotations(repo),
         "annotation_reply" => rebuild_replies(repo),
         "task" => rebuild_tasks(repo),
         "message" => rebuild_messages(repo)
       }}
    end)
    |> case do
      {:ok, tally} -> tally
    end
  end

  # Only the newest revision of each document, matching what the write path
  # indexes. Loaded a page at a time rather than streamed with a preload, which
  # `Repo.stream/2` does not do.
  defp rebuild_blocks(repo) do
    DocumentRevision
    |> distinct([revision], revision.document_id)
    |> order_by([revision], asc: revision.document_id, desc: revision.id)
    |> repo.all()
    |> Enum.chunk_every(100)
    |> Enum.reduce(0, fn revisions, count ->
      loaded = repo.preload(revisions, :blocks)
      Enum.each(loaded, &sync_document(repo, &1))
      count + Enum.sum(Enum.map(loaded, &length(&1.blocks)))
    end)
  end

  defp rebuild_annotations(repo) do
    Annotation
    |> select([annotation], {annotation.id, annotation.document_id, annotation.content})
    |> repo.all()
    |> tap_each(fn {id, document_id, content} ->
      sync(repo, "annotation", id, content, document_id: document_id)
    end)
  end

  defp rebuild_replies(repo) do
    AnnotationReply
    |> join(:inner, [reply], annotation in Annotation, on: annotation.id == reply.annotation_id)
    |> select([reply, annotation], {reply.id, annotation.document_id, reply.content})
    |> repo.all()
    |> tap_each(fn {id, document_id, content} ->
      sync(repo, "annotation_reply", id, content, document_id: document_id)
    end)
  end

  defp rebuild_tasks(repo) do
    Task
    |> select([task], {task.id, task.description})
    |> repo.all()
    |> tap_each(fn {id, description} -> sync(repo, "task", id, description) end)
  end

  defp rebuild_messages(repo) do
    Message
    |> select([message], {message.id, message.content})
    |> repo.all()
    |> tap_each(fn {id, content} -> sync(repo, "message", id, content) end)
  end

  defp tap_each(rows, fun) do
    Enum.each(rows, fun)
    length(rows)
  end

  # Describing sources

  # Deliberately not shared with `RintoPMO.References.Resolver`, which projects
  # *targets* by URI. The overlap is three of these five kinds, keyed
  # differently and shaped differently; a common layer for that would cost more
  # in indirection than the duplication does. If a third consumer wants the
  # same projections, that is when it is worth extracting.
  defp describe([]), do: []

  defp describe(links) do
    sources = links |> Enum.group_by(& &1.source_type, & &1.source_id) |> load_sources()

    Enum.map(links, fn link ->
      sources
      |> Map.get({link.source_type, link.source_id}, %{})
      |> Map.merge(%{
        source_type: link.source_type,
        source_id: link.source_id,
        label: link.label,
        position: link.position
      })
      |> then(&Map.merge(source_defaults(), &1))
    end)
  end

  defp source_defaults do
    %{document_id: nil, document_title: nil, title: nil, excerpt: nil, archived: false}
  end

  defp load_sources(by_type) do
    Enum.reduce(by_type, %{}, fn {source_type, ids}, acc ->
      Map.merge(acc, load_source(source_type, Enum.uniq(ids)))
    end)
  end

  # `source_id` for a block is its stable `block_id`, and only the newest
  # revision is indexed, so this reads the same snapshot the index was built
  # from rather than any historical copy.
  defp load_source("document_block", block_ids) do
    DocumentBlock
    |> join(:inner, [block], revision in subquery(latest_revisions()),
      on: revision.id == block.revision_id
    )
    |> join(:inner, [_block, revision], document in Document,
      on: document.id == revision.document_id
    )
    |> where([block], block.block_id in ^block_ids)
    |> select([block, revision, document], {block, revision, document.archived_at})
    |> Repo.all()
    |> Map.new(fn {block, revision, archived_at} ->
      {{"document_block", block.block_id},
       %{
         document_id: revision.document_id,
         document_title: revision.title,
         title: revision.title,
         excerpt: excerpt(block.content),
         archived: not is_nil(archived_at)
       }}
    end)
  end

  defp load_source("annotation", ids) do
    Annotation
    |> join(:inner, [annotation], revision in subquery(latest_revisions()),
      on: revision.document_id == annotation.document_id
    )
    |> where([annotation], annotation.id in ^ids)
    |> select([annotation, revision], {annotation, revision.title})
    |> Repo.all()
    |> Map.new(fn {annotation, title} ->
      {{"annotation", annotation.id},
       %{
         document_id: annotation.document_id,
         document_title: title,
         title: title,
         excerpt: excerpt(annotation.content)
       }}
    end)
  end

  defp load_source("annotation_reply", ids) do
    AnnotationReply
    |> join(:inner, [reply], annotation in Annotation, on: annotation.id == reply.annotation_id)
    |> join(:inner, [_reply, annotation], revision in subquery(latest_revisions()),
      on: revision.document_id == annotation.document_id
    )
    |> where([reply], reply.id in ^ids)
    |> select([reply, annotation, revision], {reply, annotation.document_id, revision.title})
    |> Repo.all()
    |> Map.new(fn {reply, document_id, title} ->
      {{"annotation_reply", reply.id},
       %{
         document_id: document_id,
         document_title: title,
         title: title,
         excerpt: excerpt(reply.content)
       }}
    end)
  end

  defp load_source("task", ids) do
    Task
    |> where([task], task.id in ^ids)
    |> Repo.all()
    |> Map.new(&{{"task", &1.id}, %{title: &1.title, excerpt: excerpt(&1.description)}})
  end

  # A topic's title, and the message's own position in it. Not the message
  # text: a transcript quoted out of context reads as a conclusion, which is
  # the same reason a conversation is linkable but never expandable.
  defp load_source("message", ids) do
    Message
    |> join(:inner, [message], conversation in Conversation,
      on: conversation.id == message.conversation_id
    )
    |> where([message], message.id in ^ids)
    |> select([message, conversation], {message.id, conversation.title})
    |> Repo.all()
    |> Map.new(fn {id, title} -> {{"message", id}, %{title: title}} end)
  end

  defp load_source(_unknown, _ids), do: %{}

  defp latest_revisions do
    DocumentRevision
    |> distinct([revision], revision.document_id)
    |> order_by([revision], asc: revision.document_id, desc: revision.id)
    |> select([revision], %{
      id: revision.id,
      document_id: revision.document_id,
      title: revision.title
    })
  end

  defp excerpt(nil), do: nil
  defp excerpt(""), do: nil

  defp excerpt(text) when is_binary(text) do
    trimmed = String.trim(text)
    limit = Application.fetch_env!(:rinto_pmo, __MODULE__)[:max_excerpt_chars]

    if String.length(trimmed) > limit do
      String.slice(trimmed, 0, limit) <> "…"
    else
      trimmed
    end
  end

  defp insert_all(_repo, _source_type, _source_id, _document_id, content)
       when content in [nil, ""],
       do: :ok

  defp insert_all(repo, source_type, source_id, document_id, content) do
    case References.extract(content) do
      {:ok, []} ->
        :ok

      {:ok, found} ->
        found
        |> Enum.filter(&References.linkable?(&1.reference))
        |> rows(repo, source_type, source_id, document_id)
        |> Enum.each(&repo.insert!/1)

        :ok

      {:error, _reason} ->
        :ok
    end
  end

  defp rows(found, repo, source_type, source_id, document_id) do
    documents = target_documents(repo, found)

    Enum.map(found, fn %{reference: reference, label: label, position: position} ->
      Link.changeset(%{
        source_type: source_type,
        source_id: source_id,
        source_document_id: document_id,
        target_type: reference.type,
        target_id: References.id(reference),
        target_slug: References.slug(reference),
        target_document_id: Map.get(documents, {reference.type, reference.key}),
        label: label,
        position: position
      })
    end)
  end

  # The document a block, annotation, or proposal belongs to. Resolved once per
  # body rather than once per reference: a block citing six annotations of one
  # document should not be six queries.
  #
  # A reference whose target is already gone simply has no entry, which is the
  # honest answer -- the link is kept and reported broken, not repaired.
  defp target_documents(repo, found) do
    found
    |> Enum.group_by(& &1.reference.type, & &1.reference.key)
    |> Enum.flat_map(fn {type, keys} -> parents(repo, type, Enum.uniq(keys)) end)
    |> Map.new()
  end

  defp parents(repo, "block", block_ids) do
    DocumentBlock
    |> join(:inner, [block], revision in DocumentRevision, on: revision.id == block.revision_id)
    |> where([block], block.block_id in ^block_ids)
    |> distinct([block], block.block_id)
    |> order_by([block, revision], asc: block.block_id, desc: revision.id)
    |> select([block, revision], {block.block_id, revision.document_id})
    |> repo.all()
    |> Enum.map(fn {block_id, document_id} -> {{"block", block_id}, document_id} end)
  end

  defp parents(repo, "annotation", ids) do
    Annotation
    |> where([annotation], annotation.id in ^ids)
    |> select([annotation], {annotation.id, annotation.document_id})
    |> repo.all()
    |> Enum.map(fn {id, document_id} -> {{"annotation", id}, document_id} end)
  end

  defp parents(repo, "proposal", ids) do
    BlockProposal
    |> where([proposal], proposal.id in ^ids)
    |> select([proposal], {proposal.id, proposal.document_id})
    |> repo.all()
    |> Enum.map(fn {id, document_id} -> {{"proposal", id}, document_id} end)
  end

  defp parents(_repo, "document", ids), do: Enum.map(ids, &{{"document", &1}, &1})

  defp parents(_repo, _type, _keys), do: []
end
