defmodule RintoPMO.ContentIndex do
  @moduledoc """
  The one place that says what each resource contributes to each index.

  Two things are derived from content rather than stored with it: the
  `rinto://` references a body makes (`RintoPMO.Links`) and the findable
  Two things are derived from content rather than stored with it, and only one
  of them passes through here: the `rinto://` references a body makes
  (`RintoPMO.Links`).

  Embeddings do not. Every vector lives as a column on the row whose text it
  describes, voided by whatever rewrites that text -- a changeset for most
  resources (`RintoPMO.Embeddings`), and the write path that snapshots a
  revision for a block. Nothing about them needs a second place to be
  maintained, which is why this module is much smaller than the number of
  findable types would suggest.

  ## Why this exists now and did not before

  It was deliberately not built when `Links` was the only consumer. A seam with
  one thing behind it is a guess about the second thing, and this project has
  already withdrawn two of those. The second consumer now exists, the shape it
  wants is known rather than imagined, and re-pointing the call sites was the
  one-line mechanical change it was predicted to be.

  ## Every call is inside the caller's transaction

  Both indexes are written with the resource, never after it. An index written
  in a second transaction has a window where the content says one thing and
  discovery says another, and every reader in that window is wrong.

  ## The projection precedes the query path

  Nothing computes vectors yet and nothing queries them. Maintaining the
  projection first is not getting ahead: the text a block stands for has to
  follow edits from the moment content starts changing, whatever is later done
  with it.
  """

  use RintoPMO, :context

  alias RintoPMO.Annotations.Annotation
  alias RintoPMO.Annotations.AnnotationReply
  alias RintoPMO.Conversations.Message
  alias RintoPMO.Documents.DocumentRevision
  alias RintoPMO.Links
  alias RintoPMO.Links.Link
  alias RintoPMO.Tasks.Task

  @doc """
  Indexes the references a document's newest revision makes.

  Nothing about search happens here. A block's vector lives on the block, put
  there by the write path that creates the row -- see
  `RintoPMO.Documents.put_block_snapshots/3`.
  """
  @spec sync_document(Ecto.Repo.t(), DocumentRevision.t()) :: :ok
  def sync_document(repo, %DocumentRevision{blocks: blocks} = revision) when is_list(blocks) do
    Links.sync_document(repo, revision)
  end

  @doc """
  Indexes one resource, in whatever way that kind of resource is indexed.
  """
  @spec sync(Ecto.Repo.t(), struct()) :: :ok
  def sync(repo, %Task{} = task) do
    Links.sync(repo, "task", task.id, task.description)
  end

  def sync(repo, %Annotation{} = annotation) do
    Links.sync(repo, "annotation", annotation.id, annotation.content,
      document_id: annotation.document_id
    )
  end

  def sync(repo, %AnnotationReply{} = reply) do
    document_id = annotation_document_id(repo, reply.annotation_id)
    Links.sync(repo, "annotation_reply", reply.id, reply.content, document_id: document_id)
  end

  # Messages carry references but are not themselves findable: what a topic is
  # about is its title, and its transcript is not a destination.
  def sync(repo, %Message{} = message) do
    Links.sync(repo, "message", message.id, message.content)
  end

  @doc """
  Removes everything one resource contributed, when it is really deleted.
  """
  @spec purge(Ecto.Repo.t(), struct()) :: :ok
  def purge(repo, %Task{} = task) do
    Links.purge(repo, "task", task.id)
  end

  # **Call this before the annotation is deleted.** Replies are cascaded away by
  # the database, which the indexes do not see, so their rows have to be read
  # out while the replies still exist -- otherwise every reply leaves a link row
  # pointing out of a thread that is gone.
  # **Call this before the annotation is deleted.** Replies are cascaded away by
  # the database, which the reference index does not see, so their rows have to
  # be read out while the replies still exist.
  def purge(repo, %Annotation{} = annotation) do
    AnnotationReply
    |> where([reply], reply.annotation_id == ^annotation.id)
    |> select([reply], reply.id)
    |> repo.all()
    |> Enum.each(&Links.purge(repo, "annotation_reply", &1))

    Links.purge(repo, "annotation", annotation.id)
  end

  # **Call this after the reply is deleted**, the opposite way round from an
  # annotation. A thread is projected as its own text plus its replies, and
  # re-reading it while the reply is still there would leave the removed text in
  # the projection.
  def purge(repo, %AnnotationReply{} = reply) do
    Links.purge(repo, "annotation_reply", reply.id)
  end

  @doc """
  Empties both indexes and reads them back out of every body in the system.

  This is what makes "these are indexes, not truths" checkable rather than
  merely asserted. It is also the backfill for content written before an index
  existed, and the repair for any sync a future write path forgets.

  One transaction, so a run that dies leaves the previous indexes rather than
  half of new ones. That means a long transaction on a large corpus, which is
  accepted: this is a tool a person runs, not something on a request path.

  ## Nothing here touches an embedding

  Every vector lives on the row it describes, so there is nothing to rebuild:
  a vector is missing only because the text changed and nothing has recomputed
  it yet, which is the embedding worker's business rather than this one's.

  `links` is truncated and rewritten because a link row costs nothing to
  produce -- it is read straight out of text already in hand.

  Returns a tally per kind of source read.
  """
  @spec rebuild(Ecto.Repo.t()) :: %{String.t() => non_neg_integer()}
  def rebuild(repo \\ Repo) do
    repo.transact(fn repo ->
      repo.delete_all(Link)

      tally = %{
        "document" => rebuild_documents(repo),
        "annotation" => rebuild_annotations(repo),
        "task" => rebuild_tasks(repo),
        "message" => rebuild_messages(repo)
      }

      {:ok, tally}
    end)
    |> case do
      {:ok, tally} -> tally
    end
  end

  # Only the newest revision of each document, matching what the write path
  # indexes. Loaded a page at a time rather than streamed with a preload, which
  # `Repo.stream/2` does not do.
  defp rebuild_documents(repo) do
    DocumentRevision
    |> distinct([revision], revision.document_id)
    |> order_by([revision], asc: revision.document_id, desc: revision.id)
    |> repo.all()
    |> Enum.chunk_every(100)
    |> Enum.reduce(0, fn revisions, count ->
      loaded = repo.preload(revisions, :blocks)
      Enum.each(loaded, &sync_document(repo, &1))
      count + length(loaded)
    end)
  end

  # Replies re-project their annotation rather than carrying rows of their own,
  # so reading every annotation covers both -- but each reply's own links still
  # have to be read, since those are per-reply.
  defp rebuild_annotations(repo) do
    annotations = repo.all(Annotation)
    Enum.each(annotations, &sync(repo, &1))

    AnnotationReply
    |> repo.all()
    |> Enum.each(&sync(repo, &1))

    length(annotations)
  end

  defp rebuild_tasks(repo) do
    tasks = repo.all(Task)
    Enum.each(tasks, &sync(repo, &1))
    length(tasks)
  end

  defp rebuild_messages(repo) do
    messages = repo.all(Message)
    Enum.each(messages, &sync(repo, &1))
    length(messages)
  end

  defp annotation_document_id(repo, annotation_id) do
    Annotation
    |> where([annotation], annotation.id == ^annotation_id)
    |> select([annotation], annotation.document_id)
    |> repo.one()
  end
end
