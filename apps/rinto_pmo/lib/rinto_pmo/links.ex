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
  alias RintoPMO.Documents.BlockProposal
  alias RintoPMO.Documents.DocumentBlock
  alias RintoPMO.Documents.DocumentRevision
  alias RintoPMO.Links.Link
  alias RintoPMO.References

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
