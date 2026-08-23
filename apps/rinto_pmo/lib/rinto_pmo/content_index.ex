defmodule RintoPMO.ContentIndex do
  @moduledoc """
  The one place that says what each resource contributes to each index.

  Two indexes read the same writes and want different things out of them. A
  task gives `RintoPMO.Links` its description, because that is the only field
  that can carry a reference; it gives `RintoPMO.Search` its title *and* its
  description, plus the project it belongs to. A conversation gives Links
  nothing at all -- its messages carry references, it does not -- and gives
  Search only its title.

  Rather than teach both indexes about every schema, or make every write site
  remember two calls with different arguments, that knowledge lives here.
  Contexts call `sync/2` with the thing they just wrote.

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

  ## Search projections are not settled yet

  What a query does with these rows -- lexical, vector, or both -- is still
  open. The projection is worth writing either way: "which text represents this
  resource" is the same question whether that text is matched against or
  embedded, and it has to follow edits regardless.
  """

  use RintoPMO, :context

  alias RintoPMO.Annotations.Annotation
  alias RintoPMO.Annotations.AnnotationReply
  alias RintoPMO.Conversations.Message
  alias RintoPMO.Documents.Document
  alias RintoPMO.Documents.DocumentRevision
  alias RintoPMO.Links
  alias RintoPMO.Links.Link
  alias RintoPMO.Search
  alias RintoPMO.Search.Searchable
  alias RintoPMO.Tasks.Task

  @doc """
  Indexes a document's newest revision: the document itself, and every block.

  A block is its own projection rather than part of its document's, so a hit
  lands on the section that says the thing. Blocks are purged by document first,
  because a revision can drop one entirely.
  """
  @spec sync_document(Ecto.Repo.t(), DocumentRevision.t()) :: :ok
  def sync_document(repo, %DocumentRevision{blocks: blocks} = revision) when is_list(blocks) do
    Links.sync_document(repo, revision)

    document = repo.get!(Document, revision.document_id)
    archived = not is_nil(document.archived_at)

    Search.sync(repo, "document", document.id, %{
      title: revision.title,
      body: nil,
      project_id: document.project_id,
      archived: archived
    })

    Search.purge_blocks(repo, document.id)

    Enum.each(blocks, fn block ->
      Search.sync(repo, "block", block.block_id, %{
        title: heading(block.content),
        body: block.content,
        project_id: document.project_id,
        document_id: document.id,
        archived: archived
      })
    end)

    :ok
  end

  @doc """
  Indexes one resource, in whatever way that kind of resource is indexed.
  """
  @spec sync(Ecto.Repo.t(), struct()) :: :ok
  def sync(repo, %Task{} = task) do
    Links.sync(repo, "task", task.id, task.description)

    Search.sync(repo, "task", task.id, %{
      title: task.title,
      body: task.description,
      project_id: task.project_id
    })
  end

  def sync(repo, %Annotation{} = annotation) do
    Links.sync(repo, "annotation", annotation.id, annotation.content,
      document_id: annotation.document_id
    )

    reproject_annotation(repo, annotation.id, annotation.document_id)
  end

  # A reply changes what its annotation says, so it re-projects the annotation
  # rather than getting a row of its own. A thread is one thing to find; a
  # search that returned the annotation and four of its replies as five hits
  # would be reporting the same conversation five times.
  def sync(repo, %AnnotationReply{} = reply) do
    document_id = annotation_document_id(repo, reply.annotation_id)
    Links.sync(repo, "annotation_reply", reply.id, reply.content, document_id: document_id)
    reproject_annotation(repo, reply.annotation_id, document_id)
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
    Search.purge(repo, "task", task.id)
  end

  # **Call this before the annotation is deleted.** Replies are cascaded away by
  # the database, which the indexes do not see, so their rows have to be read
  # out while the replies still exist -- otherwise every reply leaves a link row
  # pointing out of a thread that is gone.
  def purge(repo, %Annotation{} = annotation) do
    AnnotationReply
    |> where([reply], reply.annotation_id == ^annotation.id)
    |> select([reply], reply.id)
    |> repo.all()
    |> Enum.each(&Links.purge(repo, "annotation_reply", &1))

    Links.purge(repo, "annotation", annotation.id)
    Search.purge(repo, "annotation", annotation.id)
  end

  # **Call this after the reply is deleted**, the opposite way round from an
  # annotation. A thread is projected as its own text plus its replies, and
  # re-reading it while the reply is still there would leave the removed text in
  # the projection.
  def purge(repo, %AnnotationReply{} = reply) do
    Links.purge(repo, "annotation_reply", reply.id)

    reproject_annotation(
      repo,
      reply.annotation_id,
      annotation_document_id(repo, reply.annotation_id)
    )
  end

  @doc """
  Empties both indexes and reads them back out of every body in the system.

  This is what makes "these are indexes, not truths" checkable rather than
  merely asserted. It is also the backfill for content written before an index
  existed, and the repair for any sync a future write path forgets.

  One transaction, so a run that dies leaves the previous indexes rather than
  half of new ones. That means a long transaction on a large corpus, which is
  accepted: this is a tool a person runs, not something on a request path.

  Returns a tally per kind of source read.
  """
  @spec rebuild(Ecto.Repo.t()) :: %{String.t() => non_neg_integer()}
  def rebuild(repo \\ Repo) do
    repo.transact(fn repo ->
      repo.delete_all(Link)
      repo.delete_all(Searchable)

      {:ok,
       %{
         "document" => rebuild_documents(repo),
         "annotation" => rebuild_annotations(repo),
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

  # An annotation reads as its own text plus every reply under it, because that
  # is the unit somebody is looking for -- the thread, not one turn of it.
  defp reproject_annotation(repo, annotation_id, document_id) do
    case repo.get(Annotation, annotation_id) do
      nil ->
        Search.purge(repo, "annotation", annotation_id)

      annotation ->
        replies =
          AnnotationReply
          |> where([reply], reply.annotation_id == ^annotation_id)
          |> order_by([reply], asc: reply.position)
          |> select([reply], reply.content)
          |> repo.all()

        Search.sync(repo, "annotation", annotation_id, %{
          title: nil,
          body: Enum.join([annotation.content | replies], "\n\n"),
          project_id: project_of(repo, document_id),
          document_id: document_id
        })
    end
  end

  defp annotation_document_id(repo, annotation_id) do
    Annotation
    |> where([annotation], annotation.id == ^annotation_id)
    |> select([annotation], annotation.document_id)
    |> repo.one()
  end

  defp project_of(_repo, nil), do: nil

  defp project_of(repo, document_id) do
    Document
    |> where([document], document.id == ^document_id)
    |> select([document], document.project_id)
    |> repo.one()
  end

  # A block has no title field, so its first heading stands in for one. Falling
  # back to the first line keeps a block that opens with prose from being
  # nameless in a result list.
  defp heading(content) when is_binary(content) do
    content
    |> String.split("\n", parts: 2)
    |> List.first()
    |> String.trim()
    |> String.replace(~r/^#+\s*/, "")
    |> case do
      "" -> nil
      heading -> heading
    end
  end

  defp heading(_content), do: nil
end
