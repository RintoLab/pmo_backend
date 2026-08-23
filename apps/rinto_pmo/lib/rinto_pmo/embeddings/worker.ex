defmodule RintoPMO.Embeddings.Worker do
  @moduledoc """
  Fills in the vectors that content changes leave missing.

  ## The null column is the queue

  Nothing enqueues work here. A row whose text changed has `embedding` set to
  null by the changeset that changed it (see `RintoPMO.Embeddings`), and that
  is the whole of the backlog. There is no second list to keep in step with the
  first, no write site that has to remember to signal, and a row missed for any
  reason -- a service outage, a crash, a write path nobody wired up -- is picked
  up by the next pass rather than lost.

  It follows that there is no separate backfill. Backfilling *is* the normal
  path: `mix rinto.index.embed` only asks for a pass to happen now instead of
  on the next tick.

  ## Why not embed at write time

  The call takes a couple of hundred milliseconds and goes over the network. In
  the transaction that saves a document, that would make saving a document
  depend on the inference service being up. A document that cannot be saved is
  much worse than one that cannot be found for a few seconds.

  ## Pacing

  Three things keep this to one pass at a time, each covering something the
  others do not:

    * a queue of width one, so two passes never run together
    * `unique`, so repeated triggers collapse rather than pile up
    * a re-enqueue at the end of each pass -- fifteen seconds when there was
      nothing much to do, immediately when a batch came back full, so a backlog
      drains at the speed of the service rather than at the speed of the clock

  Plus `Oban.Plugins.Cron` inserting one every minute. That does nothing at all
  while the chain is healthy; it exists because a chain that only continues
  itself stops for good the first time a pass is discarded.

  ## A pass that embedded nothing says so

  Leaving the rows alone is the right answer to a service that is briefly down
  and the wrong one to a server that was never given `RINTO_AI_TOKEN`: there,
  nothing would ever be embedded, nothing would ever be findable, and the only
  evidence would be a column that is null everywhere. So a pass that came back
  empty-handed logs once -- once per pass rather than once per kind of thing,
  because seven lines say no more than one does.
  """

  use Oban.Worker,
    queue: :embeddings,
    max_attempts: 3,
    # `:incomplete` rather than a hand-written state list: Oban warns that an
    # explicit list silently stops deduplicating for any state left out of it,
    # and `:suspended` and `:retryable` are exactly the states a struggling
    # service produces.
    unique: [period: 120, states: :incomplete]

  import Ecto.Query

  require Logger

  alias RintoPMO.Annotations.Annotation
  alias RintoPMO.Annotations.AnnotationReply
  alias RintoPMO.Attachments.Attachment
  alias RintoPMO.Conversations.Conversation
  alias RintoPMO.Documents.DocumentBlock
  alias RintoPMO.Documents.DocumentRevision
  alias RintoPMO.Projects.Project
  alias RintoPMO.Repo
  alias RintoPMO.Tasks.Task
  alias RintoPMO.Utils

  # What each kind of thing is embedded as. The fields are the same ones whose
  # change voids the vector -- if these two lists ever disagree, a row is either
  # re-embedded for nothing or left stale, and neither shows up as a failure.
  @sources [
    {DocumentBlock, [:content]},
    {Task, [:title, :description]},
    {Project, [:name, :description]},
    {Annotation, [:content]},
    {AnnotationReply, [:content]},
    {Conversation, [:title]},
    {Attachment, [:filename]}
  ]

  @impl Oban.Worker
  def perform(_job) do
    filled = Enum.map(@sources, fn {schema, fields} -> fill(schema, fields) end)

    report(filled)

    if Enum.any?(filled, &(&1 == :full)) do
      # More waiting than one pass could take. Come straight back rather than
      # draining a backlog fifteen seconds at a time.
      enqueue(0)
    else
      enqueue(interval())
    end

    :ok
  end

  @doc """
  Asks for a pass, unless one is already pending.

  `unique` makes this safe to call as often as anything likes.
  """
  @spec enqueue(non_neg_integer()) :: {:ok, Oban.Job.t()} | {:error, term()}
  def enqueue(seconds \\ 0) do
    %{}
    |> __MODULE__.new(schedule_in: seconds)
    |> Oban.insert()
  end

  defp fill(schema, fields) do
    case pending(schema, fields) do
      [] ->
        :empty

      rows ->
        rows |> Enum.map(& &1.text) |> ai().embed_documents() |> store(schema, rows)
    end
  end

  defp store({:ok, embeddings}, schema, rows) do
    rows
    |> Enum.zip(embeddings)
    |> Enum.each(fn {row, embedding} -> write(schema, row.id, embedding) end)

    if length(rows) == batch_size(), do: :full, else: :done
  end

  # Leave the rows alone and let the next pass try again -- the null column
  # already says what is outstanding, so there is nothing to record. The reason
  # is carried back only so that `report/1` can say it out loud.
  defp store({:error, reason}, _schema, _rows), do: {:failed, reason}

  # One line for the pass, not one per source: every source asks the same
  # service, so a service that refused one refused all of them.
  defp report(outcomes) do
    case Enum.find(outcomes, &match?({:failed, _reason}, &1)) do
      nil ->
        :ok

      {:failed, :not_configured} ->
        Logger.warning(
          "embeddings: this server has no RINTO_AI_TOKEN, so nothing can be embedded or found"
        )

      {:failed, reason} ->
        Logger.warning("embeddings: the inference service answered #{inspect(reason)}")
    end
  end

  # Two conditions, and the second is not decoration: a row with nothing to
  # embed -- an unnamed topic, an empty block -- would otherwise be selected by
  # every pass forever, never gaining a vector and never stopping being
  # outstanding.
  defp pending(schema, fields) do
    has_text =
      Enum.reduce(fields, dynamic(false), fn field, acc ->
        dynamic([row], ^acc or fragment("btrim(coalesce(?, '')) <> ''", field(row, ^field)))
      end)

    schema
    |> where([row], is_nil(row.embedding))
    |> where(^has_text)
    |> current_only(schema)
    |> order_by([row], asc: row.id)
    |> limit(^batch_size())
    |> select([row], map(row, ^[:id | fields]))
    |> Repo.all()
    |> Enum.map(&%{id: &1.id, text: text_of(&1, fields)})
  end

  # Joined in the declared order with blanks dropped, so a task with no
  # description embeds as its title rather than as its title and a blank line.
  defp text_of(row, fields) do
    fields
    |> Enum.map(&Map.get(row, &1))
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.map_join("\n\n", &String.trim/1)
  end

  # A block has one row per revision, and only the current one is searched. The
  # superseded ones are cleared as each revision lands, so without this every
  # historical snapshot would look like outstanding work and be embedded again
  # on every pass, forever.
  defp current_only(query, DocumentBlock) do
    latest =
      DocumentRevision
      |> distinct([revision], revision.document_id)
      |> order_by([revision], asc: revision.document_id, desc: revision.id)
      |> select([revision], %{id: revision.id})

    join(query, :inner, [row], revision in subquery(latest), on: revision.id == row.revision_id)
  end

  defp current_only(query, _schema), do: query

  defp write(schema, id, embedding) do
    schema
    |> where([row], row.id == ^id)
    |> where([row], is_nil(row.embedding))
    |> Repo.update_all(set: [embedding: Pgvector.new(embedding)])
  end

  defp ai, do: Utils.module(:ai)

  defp batch_size, do: config(:batch_size)
  defp interval, do: config(:interval_seconds)

  defp config(key) do
    :rinto_pmo
    |> Application.fetch_env!(__MODULE__)
    |> Keyword.fetch!(key)
  end
end
