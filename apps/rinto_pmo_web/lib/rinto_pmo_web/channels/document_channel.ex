defmodule RintoPMOWeb.DocumentChannel do
  @moduledoc """
  A document, as the client watches it work.

  ## Addressed by document, not by attempt

      socket.channel("document:" + documentId, {})

  Which decomposition attempt is running is an implementation detail and is
  kept out of the client's way, the same way `RintoPMOWeb.ConversationChannel`
  hides which pi process is carrying a topic. The channel outlives any attempt:
  a client stays joined across one finishing and the next one starting, and
  never has to go and find an id before it can watch again.

  Joining starts nothing. Breaking a document down is
  `POST /documents/{id}/decompose`, because it costs a model call and that
  should not be something opening a panel can do.

  ## Joining

  A join immediately pushes the most recent attempt, so a client arriving after
  the interesting part still knows where things stand:

      {"decomposition": attempt | null}

  ## Server to client

    * `"decomposition"` -- `%{"decomposition" => attempt | null}`, the attempt's
      row. Pushed on join and again on every change of state: `pending` when
      one is queued, `running` when the model call starts, then `succeeded`
      with `result_document_id`, or `failed` with `error`
    * `"decomposition_output"` -- `%{"decomposition_id" => id, "chunk" => text}`,
      more of the model's output. **Append them in order.** They are pieces of
      a stream, not lines and not whole messages -- a chunk may end mid-word
    * `"annotation_reply"` -- `%{"job_id" => id, "annotation_id" => id,
      "status" => "succeeded" | "failed", "error" => text | null}`, the AI
      reply somebody asked for on one annotation is over. It carries no reply
      text: re-read the thread with `GET /annotations/{id}`, which is what the
      panel showing it does anyway. There is no `"annotation_reply_output"` --
      a reply is a paragraph, not minutes of streamed text

  ## Output is live only

  Nothing replays. A client that joins while an attempt is running sees the
  chunks from that moment on, not the ones it missed, and the row it got on
  join is what tells it something is in progress. When the attempt finishes,
  the finished text is in the document that `result_document_id` names, which
  is the copy that matters.

  This is the honest shape for a stream nobody stores. A second tab catching up
  mid-run would need the output buffered per attempt, which is a real feature
  and not this one -- see `RintoPMO.Documents.Notifier`.
  """

  use RintoPMOWeb, :channel

  alias RintoPMO.Documents.Notifier
  alias RintoPMO.Utils
  alias RintoPMOWeb.V1.DecompositionJSON

  @impl true
  def join("document:" <> document_id, _params, socket) do
    case fetch_document(document_id) do
      {:ok, document} ->
        send(self(), :after_join)
        {:ok, assign(socket, :document, document)}

      :error ->
        {:error, %{reason: "not_found"}}
    end
  end

  @impl true
  def handle_info(:after_join, socket) do
    document = socket.assigns.document
    :ok = Notifier.subscribe(document.id)
    push(socket, "decomposition", %{decomposition: latest(document)})
    {:noreply, socket}
  end

  def handle_info({:decomposition_updated, decomposition}, socket) do
    push(socket, "decomposition", %{decomposition: DecompositionJSON.data(decomposition)})
    {:noreply, socket}
  end

  def handle_info({:decomposition_output, decomposition_id, chunk}, socket) do
    push(socket, "decomposition_output", %{decomposition_id: decomposition_id, chunk: chunk})
    {:noreply, socket}
  end

  def handle_info({:annotation_reply, job_id, annotation_id, status, error}, socket) do
    push(socket, "annotation_reply", %{
      job_id: job_id,
      annotation_id: annotation_id,
      status: status,
      error: error
    })

    {:noreply, socket}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  defp latest(document) do
    case documents().latest_decomposition(document) do
      nil -> nil
      decomposition -> DecompositionJSON.data(decomposition)
    end
  end

  defp fetch_document(document_id) do
    {:ok, documents().get_document!(document_id)}
  rescue
    Ecto.NoResultsError -> :error
    Ecto.Query.CastError -> :error
  end

  defp documents, do: Utils.module(:documents)
end
