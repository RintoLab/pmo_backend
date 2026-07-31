defmodule RintoPMO.Annotations do
  @moduledoc """
  The context for document annotations and flat follow-up replies.
  """

  use RintoPMO, :context

  alias RintoPMO.Annotations.Annotation
  alias RintoPMO.Annotations.AnnotationReply
  alias RintoPMO.Documents.Document

  defmodule Behaviour do
    @moduledoc false

    alias RintoPMO.Annotations.Annotation
    alias RintoPMO.Annotations.AnnotationReply
    alias RintoPMO.Documents.Document

    @type filter :: %{optional(:block_id) => UUIDv7.t() | nil}

    @callback list_annotations(Document.t(), filter()) :: [Annotation.t()]
    @callback get_annotation!(Document.t(), UUIDv7.t()) :: Annotation.t()
    @callback create_annotation(Document.t(), map()) ::
                {:ok, Annotation.t()} | {:error, Ecto.Changeset.t()}
    @callback update_annotation(Annotation.t(), map()) ::
                {:ok, Annotation.t()} | {:error, Ecto.Changeset.t()}
    @callback delete_annotation(Annotation.t()) ::
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
    %Annotation{document_id: document.id}
    |> Annotation.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Updates annotation content or anchor snapshots.
  """
  @impl true
  def update_annotation(%Annotation{} = annotation, attrs) do
    annotation
    |> Annotation.update_changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Deletes an annotation and its replies.
  """
  @impl true
  def delete_annotation(%Annotation{} = annotation) do
    Repo.delete(annotation)
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
    end)
  end

  @doc """
  Updates a reply's content. Position is immutable.
  """
  @impl true
  def update_reply(%AnnotationReply{} = reply, attrs) do
    reply
    |> AnnotationReply.update_changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Deletes a reply without renumbering later positions.
  """
  @impl true
  def delete_reply(%AnnotationReply{} = reply) do
    Repo.delete(reply)
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

  defp filter_annotations(query, filter) do
    Enum.reduce(filter, query, fn
      {:block_id, nil}, query ->
        where(query, [annotation], is_nil(annotation.block_id))

      {:block_id, block_id}, query ->
        where(query, [annotation], annotation.block_id == ^block_id)

      {_other, _value}, query ->
        query
    end)
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
