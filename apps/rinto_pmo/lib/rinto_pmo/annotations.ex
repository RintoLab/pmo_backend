defmodule RintoPMO.Annotations do
  @moduledoc """
  The context for document annotations and flat follow-up replies.
  """

  use RintoPMO, :context

  alias RintoPMO.Annotations.Annotation
  alias RintoPMO.Annotations.AnnotationReply
  alias RintoPMO.Documents.Document
  alias RintoPMO.Links

  defmodule Behaviour do
    @moduledoc false

    alias RintoPMO.Annotations.Annotation
    alias RintoPMO.Annotations.AnnotationReply
    alias RintoPMO.Documents.Document

    @type filter :: %{
            optional(:block_id) => UUIDv7.t() | nil,
            optional(:status) => Annotation.status(),
            optional(:pending_conclusion) => boolean()
          }

    @callback list_annotations(Document.t(), filter()) :: [Annotation.t()]
    @callback get_annotation!(Document.t(), UUIDv7.t()) :: Annotation.t()
    @callback create_annotation(Document.t(), map()) ::
                {:ok, Annotation.t()} | {:error, Ecto.Changeset.t()}
    @callback update_annotation(Annotation.t(), map()) ::
                {:ok, Annotation.t()} | {:error, Ecto.Changeset.t()}
    @callback delete_annotation(Annotation.t()) ::
                {:ok, Annotation.t()} | {:error, Ecto.Changeset.t()}

    @callback resolve_annotation(Annotation.t(), map()) ::
                {:ok, Annotation.t()} | {:error, Ecto.Changeset.t()}
    @callback dismiss_annotation(Annotation.t()) ::
                {:ok, Annotation.t()} | {:error, Ecto.Changeset.t()}
    @callback reopen_annotation(Annotation.t()) ::
                {:ok, Annotation.t()} | {:error, Ecto.Changeset.t()}

    @callback create_reply(Annotation.t(), map()) ::
                {:ok, AnnotationReply.t()} | {:error, Ecto.Changeset.t()}
    @callback update_reply(AnnotationReply.t(), map()) ::
                {:ok, AnnotationReply.t()} | {:error, Ecto.Changeset.t()}
    @callback delete_reply(AnnotationReply.t()) ::
                {:ok, AnnotationReply.t()} | {:error, Ecto.Changeset.t()}
    @callback get_reply!(Annotation.t(), UUIDv7.t()) :: AnnotationReply.t()
  end

  @behaviour Behaviour

  @doc """
  Lists annotations for a document without preloading replies.

  Newest annotations first.
  """
  @impl true
  def list_annotations(%Document{} = document, filter) when is_map(filter) do
    document
    |> Ecto.assoc(:annotations)
    |> filter_annotations(filter)
    |> order_by([annotation], desc: annotation.id)
    |> Repo.all()
  end

  @doc """
  Fetches one annotation scoped to a document, with replies ordered by position.
  """
  @impl true
  def get_annotation!(%Document{} = document, id) do
    document
    |> Ecto.assoc(:annotations)
    |> where([annotation], annotation.id == ^id)
    |> Repo.one!()
    |> Repo.preload(:replies)
  end

  @doc """
  Creates an annotation on a document. Replies start empty.
  """
  @impl true
  def create_annotation(%Document{} = document, attrs) do
    Repo.transact(fn repo ->
      %Annotation{document_id: document.id}
      |> Annotation.changeset(attrs)
      |> repo.insert()
      |> index(repo)
    end)
  end

  @doc """
  Updates annotation content or anchor snapshots.
  """
  @impl true
  def update_annotation(%Annotation{} = annotation, attrs) do
    Repo.transact(fn repo ->
      annotation
      |> Annotation.update_changeset(attrs)
      |> repo.update()
      |> index(repo)
    end)
  end

  @doc """
  Deletes an annotation and its replies.
  """
  @impl true
  def delete_annotation(%Annotation{} = annotation) do
    Repo.transact(fn repo ->
      Links.purge(repo, "annotation", annotation.id)
      repo.delete(annotation)
    end)
  end

  @doc """
  Marks an annotation resolved, optionally naming the revision that settled it.

  `attrs` may carry `resolved_by_revision_id`. Status changes never travel
  through `update_annotation/2`, so that editing wording cannot close a thread.
  """
  @impl true
  def resolve_annotation(%Annotation{} = annotation, attrs) do
    annotation
    |> Annotation.status_changeset(:resolved, attrs)
    |> Repo.update()
  end

  @doc """
  Marks an annotation dismissed: considered and declined.

  This is the "no" that is not a deletion. The opinion stood, the answer was
  no, and the record of both survives -- deleting instead would take the
  replies with it and leave the topics that discussed it pointing at nothing.

  Clears `resolved_by_revision_id`: nothing was changed in the document, so no
  revision settled this.
  """
  @impl true
  def dismiss_annotation(%Annotation{} = annotation) do
    annotation
    |> Annotation.status_changeset(:dismissed)
    |> Repo.update()
  end

  @doc """
  Returns an annotation to `:open`, clearing `resolved_by_revision_id`.
  """
  @impl true
  def reopen_annotation(%Annotation{} = annotation) do
    annotation
    |> Annotation.status_changeset(:open)
    |> Repo.update()
  end

  @doc """
  Appends a reply with the next monotonic position.
  """
  @impl true
  def create_reply(%Annotation{} = annotation, attrs) do
    Repo.transact(fn repo ->
      locked =
        Annotation
        |> where([candidate], candidate.id == ^annotation.id)
        |> lock("FOR UPDATE")
        |> repo.one!()

      position = next_reply_position(repo, locked.id)

      %AnnotationReply{annotation_id: locked.id, position: position}
      |> AnnotationReply.changeset(attrs)
      |> repo.insert()
      |> index_reply(repo, locked.document_id)
    end)
  end

  @doc """
  Updates a reply's content. Position is immutable.
  """
  @impl true
  def update_reply(%AnnotationReply{} = reply, attrs) do
    Repo.transact(fn repo ->
      reply
      |> AnnotationReply.update_changeset(attrs)
      |> repo.update()
      |> index_reply(repo, document_id_of(repo, reply))
    end)
  end

  @doc """
  Deletes a reply without renumbering later positions.
  """
  @impl true
  def delete_reply(%AnnotationReply{} = reply) do
    Repo.transact(fn repo ->
      Links.purge(repo, "annotation_reply", reply.id)
      repo.delete(reply)
    end)
  end

  @doc """
  Fetches a reply scoped to an annotation.
  """
  @impl true
  def get_reply!(%Annotation{} = annotation, id) do
    annotation
    |> Ecto.assoc(:replies)
    |> where([reply], reply.id == ^id)
    |> Repo.one!()
  end

  # In the same transaction as the write, so that the body and "who points at
  # this?" never disagree, not even briefly. See `RintoPMO.Links`.
  defp index({:ok, %Annotation{} = annotation}, repo) do
    Links.sync(repo, "annotation", annotation.id, annotation.content,
      document_id: annotation.document_id
    )

    {:ok, annotation}
  end

  defp index(result, _repo), do: result

  defp index_reply({:ok, %AnnotationReply{} = reply}, repo, document_id) do
    Links.sync(repo, "annotation_reply", reply.id, reply.content, document_id: document_id)
    {:ok, reply}
  end

  defp index_reply(result, _repo, _document_id), do: result

  # A reply knows its annotation but not its document, and the index wants the
  # document so that everything written inside one is reachable together.
  defp document_id_of(repo, %AnnotationReply{annotation_id: annotation_id}) do
    Annotation
    |> where([annotation], annotation.id == ^annotation_id)
    |> select([annotation], annotation.document_id)
    |> repo.one()
  end

  defp filter_annotations(query, filter) do
    Enum.reduce(filter, query, fn
      {:block_id, nil}, query ->
        where(query, [annotation], is_nil(annotation.block_id))

      {:block_id, block_id}, query ->
        where(query, [annotation], annotation.block_id == ^block_id)

      {:status, status}, query ->
        where(query, [annotation], annotation.status == ^status)

      {:pending_conclusion, true}, query ->
        where(
          query,
          [annotation],
          annotation.status == :open and
            annotation.id in subquery(concluded_annotation_ids())
        )

      {:pending_conclusion, false}, query ->
        where(
          query,
          [annotation],
          annotation.status != :open or
            annotation.id not in subquery(concluded_annotation_ids())
        )

      {_other, _value}, query ->
        query
    end)
  end

  # "A conclusion is waiting on you": still open, and a reply on it came out of
  # a conversation. The reply is the AI saying it is done; the open status is
  # nobody having decided yet.
  #
  # Deliberately not keyed on whether a human has *read* it. Clearing the
  # marker on read would make it vanish at precisely the moment intervention is
  # most needed -- the annotation unresolved, the document unchanged, and the
  # prompt gone from view. See docs/document-conversations.md.
  defp concluded_annotation_ids do
    AnnotationReply
    |> where([reply], not is_nil(reply.source_message_id))
    |> select([reply], reply.annotation_id)
  end

  defp next_reply_position(repo, annotation_id) do
    AnnotationReply
    |> where([reply], reply.annotation_id == ^annotation_id)
    |> select([reply], max(reply.position))
    |> repo.one()
    |> case do
      nil -> 0
      max_position -> max_position + 1
    end
  end
end
