defmodule RintoPMO.Documents.Notifier do
  @moduledoc """
  Says what is happening to a document, to everyone watching that document.

  Built the same way as `RintoPMO.Conversations.Notifier` and for the same
  reason: the work happens somewhere other than the connection that asked for
  it. A decomposition runs in a background job, so there may be no connection
  at all by the time it finishes, and there may be several -- another tab, the
  list beside it.

  ## Addressed by document, not by attempt

  The topic is the document, the way a conversation channel is addressed by
  conversation and not by the pi process carrying it. The reasoning carries
  over unchanged: which attempt is running is an implementation detail, the
  subscription has to outlive it, and a client that reconnects knows the
  document it is looking at but would have to go and find the new attempt id
  before it could resubscribe.

  ## Three kinds of message

    * `{:decomposition_updated, decomposition}` -- the attempt's row moved.
      The whole row, so a new field never needs a new message.
    * `{:decomposition_output, decomposition_id, chunk}` -- more text arrived
      from the model. Carries the attempt's id rather than the row, because
      thousands of these go past and re-reading the row for each would be a
      query per chunk to say something the subscriber already knows.
    * `{:annotation_reply, job_id, annotation_id, status, error}` -- the AI
      reply somebody asked for is over, one way or the other. Carries the ids
      and not the reply: what changed is a thread the client re-reads, the way
      an estimation announces itself without carrying the numbers.
    * `{:document_review, job_id, document_id, status, error, count}` -- a
      review that included this document is over. Carries how many notes it
      left *here*, because a review spans several documents and each one is
      told separately; the notes themselves are re-read like any others.

  Output is **not** replayed to somebody who joins late: it is broadcast as it
  arrives and kept nowhere. What a late joiner gets is the row, which is enough
  to say "still running" and, once it is over, everything that matters. Keeping
  a buffer per attempt so a second tab could catch up is a real feature, and
  not this one.
  """

  alias RintoPMO.Annotations.Annotation
  alias RintoPMO.Documents.Decomposition

  @pubsub RintoPMO.PubSub

  @doc """
  The PubSub topic carrying one document's activity.

  Deliberately equal to the channel topic clients join, so there is one name
  for "this document" rather than two that have to be kept in step.
  """
  @spec topic(UUIDv7.t()) :: String.t()
  def topic(document_id) when is_binary(document_id), do: "document:" <> document_id

  @doc """
  Subscribes the calling process to a document's activity.
  """
  @spec subscribe(UUIDv7.t(), atom()) :: :ok | {:error, term()}
  def subscribe(document_id, pubsub \\ @pubsub) do
    Phoenix.PubSub.subscribe(pubsub, topic(document_id))
  end

  @doc """
  Announces the current state of a decomposition attempt.
  """
  @spec broadcast_decomposition(Decomposition.t(), atom()) :: :ok | {:error, term()}
  def broadcast_decomposition(%Decomposition{} = decomposition, pubsub \\ @pubsub) do
    Phoenix.PubSub.broadcast(
      pubsub,
      topic(decomposition.source_document_id),
      {:decomposition_updated, decomposition}
    )
  end

  @doc """
  Passes on text as the model produces it.
  """
  @spec broadcast_output(Decomposition.t(), String.t(), atom()) :: :ok | {:error, term()}
  def broadcast_output(%Decomposition{} = decomposition, chunk, pubsub \\ @pubsub)
      when is_binary(chunk) do
    Phoenix.PubSub.broadcast(
      pubsub,
      topic(decomposition.source_document_id),
      {:decomposition_output, decomposition.id, chunk}
    )
  end

  @doc """
  Says that an asked-for AI reply is over, and whether it worked.

  Addressed to the document rather than to the annotation, because that is the
  subscription a client already holds: somebody reading a document has one
  socket for it, not one per note they might click.

  No streaming counterpart. A decomposition is minutes of text a person watches
  arrive; a reply is a paragraph, and a spinner that ends with the thread
  redrawn is the whole of what there is to show.
  """
  @spec broadcast_annotation_reply(
          integer(),
          Annotation.t(),
          :succeeded | :failed,
          String.t() | nil,
          atom()
        ) :: :ok | {:error, term()}
  def broadcast_annotation_reply(
        job_id,
        %Annotation{} = annotation,
        status,
        error,
        pubsub \\ @pubsub
      ) do
    Phoenix.PubSub.broadcast(
      pubsub,
      topic(annotation.document_id),
      {:annotation_reply, job_id, annotation.id, status, error}
    )
  end

  @doc """
  Says that a review covering this document is over, and what it left here.

  Sent once per document in the review rather than once per review: a client is
  subscribed to a document, and the selection somebody made is not a thing it
  knows about. `count` is how many notes landed on *this* document, so a tab
  can say what happened without diffing the list it is about to re-read.

  Takes the document's id rather than the document, unlike the reply above.
  Reviews name their documents by id all the way through -- the job carries
  ids, and a row loaded only to be broadcast is a query for a field nobody
  reads.
  """
  @spec broadcast_review(
          integer(),
          UUIDv7.t(),
          :succeeded | :failed,
          String.t() | nil,
          non_neg_integer(),
          atom()
        ) :: :ok | {:error, term()}
  def broadcast_review(job_id, document_id, status, error, count, pubsub \\ @pubsub)
      when is_binary(document_id) and is_integer(count) do
    Phoenix.PubSub.broadcast(
      pubsub,
      topic(document_id),
      {:document_review, job_id, document_id, status, error, count}
    )
  end
end
