defmodule RintoPMO.Search do
  @moduledoc """
  Finding things by what they mean rather than by what they are called.

  ## Two stages, and the second one is what decides quality

  A query is embedded, the nearest hundred rows are pulled by cosine distance,
  and a reranker reads the query against each of them and scores it properly.
  The first stage is cheap and approximate; the second is the one that is
  actually right.

  A hundred is not a round number picked for comfort. Measured on this system's
  own content, the best result after reranking sat at cosine rank 27, 25 and 56
  across three queries -- so a candidate set of twenty would have missed all
  three and fifty would have missed one. The embedding model is small
  (Qwen3-Embedding-0.6B) and its recall is correspondingly rough, which is
  exactly the situation reranking exists for. Latency is not the constraint:
  reranking a hundred candidates costs about 100ms more than reranking twenty.

  ## One type at a time

  There is no ranked search across types. Nothing merges seven KNN queries and
  claims a global top-20, because there is no need to: an agent enumerating
  tasks has `task list`, and one enumerating documents has `doc list`. Asking
  about two kinds of thing means asking twice.

  ## What matches is not always what is returned

  A search unit is whatever carries an embedding; a result is whatever a caller
  can address and open. They coincide for a task, and deliberately do not for
  the two things that are read as wholes:

    * searching `document` matches **blocks** and answers with their documents,
      because a document's content is its sections
    * searching `annotation` matches annotations **and their replies** and
      answers with the thread, because a conclusion three replies down belongs
      to the thread that produced it

  Duplicates collapse to their best-scoring member, so a document whose four
  sections all match is one result rather than four.

  ## Rows without a vector do not participate

  A row waiting to be embedded is not findable. Something written in the last
  few seconds may therefore not be there yet -- see
  `RintoPMO.Embeddings.Worker` on why that gap exists and why it is short.
  """

  use RintoPMO, :context

  alias RintoPMO.Annotations.Annotation
  alias RintoPMO.Annotations.AnnotationReply
  alias RintoPMO.Attachments.Attachment
  alias RintoPMO.Conversations.Conversation
  alias RintoPMO.Documents.BlockEmbedding
  alias RintoPMO.Documents.Document
  alias RintoPMO.Documents.DocumentRevision
  alias RintoPMO.Projects.Project
  alias RintoPMO.References
  alias RintoPMO.References.Reference
  alias RintoPMO.Tasks.Task
  alias RintoPMO.Utils

  @typedoc """
  One result, addressed the way everything else in this system addresses it.

  `uri` is the point: it is what a model pastes into a body, and what
  `RintoPMO.References.parse/1` reads back. Nothing assembles an id.
  """
  @type result :: %{
          uri: String.t(),
          type: String.t(),
          title: String.t() | nil,
          excerpt: String.t() | nil,
          document_id: UUIDv7.t() | nil,
          document_title: String.t() | nil,
          score: float(),
          archived: boolean()
        }

  @type option ::
          {:type, String.t()}
          | {:project_id, UUIDv7.t() | nil}
          | {:include_archived, boolean()}
          | {:limit, pos_integer()}

  defmodule Behaviour do
    @moduledoc false

    @callback search(String.t(), keyword()) ::
                {:ok, [RintoPMO.Search.result()]}
                | {:error, :unsearchable_type, map()}
                | {:error, term()}
  end

  @behaviour Behaviour

  @default_type "block"

  @doc """
  Searches one kind of thing, best first.

  Options: `:type` (default `"block"`), `:project_id`, `:include_archived`,
  `:limit`.

  Answers `{:error, :unsearchable_type, _}` for a type nothing is indexed under
  -- a proposal, or a kind of thing this build has never heard of. That is a
  mistake in the request rather than an empty result, and saying so beats
  answering "nothing found" to a question that could never have found anything.
  """
  @impl true
  @spec search(String.t(), [option()]) ::
          {:ok, [result()]} | {:error, :unsearchable_type, map()} | {:error, term()}
  def search(query, opts \\ []) when is_binary(query) do
    type = Keyword.get(opts, :type) || @default_type

    if searchable?(type) do
      run(query, type, opts)
    else
      {:error, :unsearchable_type, %{type: type, searchable: searchable_types()}}
    end
  end

  @doc """
  The types `search/2` will accept.
  """
  @spec searchable_types() :: [String.t()]
  def searchable_types do
    References.types()
    |> Enum.filter(fn {_type, capabilities} -> capabilities.searchable end)
    |> Enum.map(fn {type, _capabilities} -> type end)
    |> Enum.sort()
  end

  defp searchable?(type), do: type in searchable_types()

  defp run(query, type, opts) do
    with {:ok, vector} <- ai().embed_query(query) do
      candidates = candidates(type, Pgvector.new(vector), opts)

      case rank(query, candidates) do
        {:ok, ranked} -> {:ok, Enum.take(ranked, Keyword.get(opts, :limit, result_limit()))}
        error -> error
      end
    end
  end

  # Reranking is what the candidate set was gathered for, so a reranker that is
  # unavailable is a failed search rather than a chance to hand back the cosine
  # order. Cosine order is the thing measured to be wrong.
  defp rank(_query, []), do: {:ok, []}

  defp rank(query, candidates) do
    with {:ok, rankings} <- ai().rerank(query, Enum.map(candidates, & &1.text)) do
      {:ok,
       rankings
       |> Enum.map(fn %{index: index, score: score} ->
         candidates |> Enum.at(index) |> Map.put(:score, score)
       end)
       |> collapse()}
    end
  end

  # A document whose four sections all match is one result, scored by its best
  # section. Rankings arrive best-first, so the first of each key wins.
  defp collapse(scored) do
    scored
    |> Enum.reduce({[], MapSet.new()}, fn candidate, {kept, seen} ->
      key = {candidate.type, candidate.key}

      if MapSet.member?(seen, key) do
        {kept, seen}
      else
        {[present(candidate) | kept], MapSet.put(seen, key)}
      end
    end)
    |> elem(0)
    |> Enum.reverse()
  end

  defp present(candidate) do
    %{
      uri: References.to_uri(%Reference{type: candidate.type, key: candidate.key}),
      type: candidate.type,
      title: candidate.title,
      excerpt: excerpt(candidate.text),
      document_id: candidate.document_id,
      document_title: candidate.document_title,
      score: candidate.score,
      archived: candidate.archived
    }
  end

  # Candidates

  # `document` and `block` read the same rows and differ only in what they
  # answer with: the section that matched, or the document it is part of.
  defp candidates("block", vector, opts), do: block_candidates(vector, opts, "block")
  defp candidates("document", vector, opts), do: block_candidates(vector, opts, "document")

  defp candidates("annotation", vector, opts) do
    (annotation_candidates(vector, opts) ++ reply_candidates(vector, opts))
    |> Enum.sort_by(& &1.distance)
    |> Enum.take(recall_limit())
  end

  defp candidates("task", vector, opts) do
    Task
    |> nearest(vector, opts)
    |> select([row], %{
      key: row.id,
      text: fragment("btrim(? || E'\\n\\n' || coalesce(?, ''))", row.title, row.description),
      title: row.title,
      distance: fragment("? <=> ?", row.embedding, ^vector)
    })
    |> Repo.all()
    |> Enum.map(&candidate(&1, "task"))
  end

  defp candidates("project", vector, opts) do
    Project
    |> nearest(vector, opts)
    |> then(fn query ->
      if Keyword.get(opts, :include_archived, false) do
        query
      else
        where(query, [row], row.status != :archived)
      end
    end)
    |> select([row], %{
      key: row.slug,
      text: fragment("btrim(? || E'\\n\\n' || coalesce(?, ''))", row.name, row.description),
      title: row.name,
      distance: fragment("? <=> ?", row.embedding, ^vector),
      archived: fragment("? = 'archived'", row.status)
    })
    |> Repo.all()
    |> Enum.map(&candidate(&1, "project"))
  end

  defp candidates("conversation", vector, opts) do
    Conversation
    |> nearest(vector, opts)
    |> select([row], %{
      key: row.id,
      text: row.title,
      title: row.title,
      distance: fragment("? <=> ?", row.embedding, ^vector)
    })
    |> Repo.all()
    |> Enum.map(&candidate(&1, "conversation"))
  end

  defp candidates("attachment", vector, opts) do
    Attachment
    |> nearest(vector, opts)
    |> select([row], %{
      key: row.id,
      text: row.filename,
      title: row.filename,
      distance: fragment("? <=> ?", row.embedding, ^vector)
    })
    |> Repo.all()
    |> Enum.map(&candidate(&1, "attachment"))
  end

  defp block_candidates(vector, opts, answering_as) do
    BlockEmbedding
    |> nearest(vector, opts)
    |> then(fn query ->
      if Keyword.get(opts, :include_archived, false),
        do: query,
        else: where(query, [row], not row.archived)
    end)
    |> select([row], %{
      block_id: row.block_id,
      text: row.body,
      title: row.title,
      document_id: row.document_id,
      archived: row.archived,
      distance: fragment("? <=> ?", row.embedding, ^vector)
    })
    |> Repo.all()
    |> with_document_titles()
    |> Enum.map(fn row ->
      key = if answering_as == "block", do: row.block_id, else: row.document_id
      title = if answering_as == "block", do: row.title, else: row.document_title

      row
      |> Map.merge(%{key: key, title: title})
      |> candidate(answering_as)
    end)
  end

  defp annotation_candidates(vector, opts) do
    Annotation
    |> nearest(vector, opts)
    |> join(:inner, [row], document in Document, on: document.id == row.document_id)
    |> scoped(opts, :document)
    |> select([row, document], %{
      key: row.id,
      text: row.content,
      document_id: row.document_id,
      archived: not is_nil(document.archived_at),
      distance: fragment("? <=> ?", row.embedding, ^vector)
    })
    |> Repo.all()
    |> annotation_titles()
  end

  # A reply is a search unit but never a result: what a reader wants is the
  # thread it belongs to, which is what its `annotation_id` becomes here.
  defp reply_candidates(vector, opts) do
    AnnotationReply
    |> nearest(vector, opts)
    |> join(:inner, [row], annotation in Annotation, on: annotation.id == row.annotation_id)
    |> join(:inner, [_row, annotation], document in Document,
      on: document.id == annotation.document_id
    )
    |> scoped(opts, :document)
    |> select([row, annotation, document], %{
      key: annotation.id,
      text: row.content,
      document_id: annotation.document_id,
      archived: not is_nil(document.archived_at),
      distance: fragment("? <=> ?", row.embedding, ^vector)
    })
    |> Repo.all()
    |> annotation_titles()
  end

  # An annotation has no title of its own, so it is named by the document it
  # was written on.
  defp annotation_titles([]), do: []

  defp annotation_titles(rows) do
    titles = document_titles(Enum.map(rows, & &1.document_id))

    Enum.map(rows, fn row ->
      title = Map.get(titles, row.document_id)

      row
      |> Map.merge(%{title: title, document_title: title})
      |> candidate("annotation")
    end)
  end

  defp with_document_titles([]), do: []

  defp with_document_titles(rows) do
    titles = document_titles(Enum.map(rows, & &1.document_id))
    Enum.map(rows, &Map.put(&1, :document_title, Map.get(titles, &1.document_id)))
  end

  defp document_titles(document_ids) do
    DocumentRevision
    |> distinct([revision], revision.document_id)
    |> order_by([revision], asc: revision.document_id, desc: revision.id)
    |> where([revision], revision.document_id in ^Enum.uniq(document_ids))
    |> select([revision], {revision.document_id, revision.title})
    |> Repo.all()
    |> Map.new()
  end

  # A row with no vector cannot be compared to anything, so it is not a
  # candidate rather than an infinitely distant one.
  defp nearest(schema, vector, opts) do
    schema
    |> where([row], not is_nil(row.embedding))
    |> scoped(opts, :row)
    |> order_by([row], asc: fragment("? <=> ?", row.embedding, ^vector))
    |> limit(^recall_limit())
  end

  # Scope narrows before distance does, which is the filter that matters first:
  # finding the right thing is usually a matter of looking in the right place.
  defp scoped(query, opts, on) do
    case Keyword.get(opts, :project_id) do
      nil ->
        query

      project_id when on == :row ->
        where(query, [row], row.project_id == ^project_id)

      project_id ->
        where(query, [_row, _annotation, document], document.project_id == ^project_id)
    end
  end

  defp candidate(row, type) do
    %{
      type: type,
      key: Map.fetch!(row, :key),
      text: Map.get(row, :text) || "",
      title: Map.get(row, :title),
      document_id: Map.get(row, :document_id),
      document_title: Map.get(row, :document_title),
      archived: Map.get(row, :archived, false),
      distance: Map.fetch!(row, :distance)
    }
  end

  defp excerpt(nil), do: nil
  defp excerpt(""), do: nil

  defp excerpt(text) do
    trimmed = String.trim(text)
    limit = config(:max_excerpt_chars)

    if String.length(trimmed) > limit,
      do: String.slice(trimmed, 0, limit) <> "…",
      else: trimmed
  end

  defp ai, do: Utils.module(:ai)
  defp recall_limit, do: config(:recall_limit)
  defp result_limit, do: config(:result_limit)

  defp config(key) do
    :rinto_pmo
    |> Application.fetch_env!(__MODULE__)
    |> Keyword.fetch!(key)
  end
end
