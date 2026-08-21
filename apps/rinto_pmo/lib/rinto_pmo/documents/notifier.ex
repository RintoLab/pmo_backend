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

  ## Two kinds of message

    * `{:decomposition_updated, decomposition}` -- the attempt's row moved.
      The whole row, so a new field never needs a new message.
    * `{:decomposition_output, decomposition_id, chunk}` -- more text arrived
      from the model. Carries the attempt's id rather than the row, because
      thousands of these go past and re-reading the row for each would be a
      query per chunk to say something the subscriber already knows.

  Output is **not** replayed to somebody who joins late: it is broadcast as it
  arrives and kept nowhere. What a late joiner gets is the row, which is enough
  to say "still running" and, once it is over, everything that matters. Keeping
  a buffer per attempt so a second tab could catch up is a real feature, and
  not this one.
  """

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
end
