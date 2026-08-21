defmodule RintoPMOWeb.TaskChannel do
  @moduledoc """
  A task, as the client hears about estimations finishing on it.

  ## Addressed by task, not by attempt

      socket.channel("task:" + taskId, {})

  The channel outlives any one estimation: a client stays joined across one
  finishing and the next one starting, and never has to go and find an id
  before it can listen.

  Joining starts nothing. Estimating is `POST /tasks/{id}/estimate` with a
  `kind`, because it costs a model call and that should not be something
  opening a panel can do.

  ## Joining pushes nothing

  A join is a subscription and only that. There is no attempt row to hand back
  and no state to catch up on: a client either holds a job id it started, in
  which case it is waiting for the message below, or it holds nothing, in
  which case there is nothing it is waiting for.

  What a client holding a job id does about a message it missed while
  disconnected is ask `GET /jobs/{job_id}` -- see `RintoPMO.Jobs`.

  ## Server to client

    * `"estimation"` -- `%{"job_id" => id, "kind" => "difficulty" | "time",
      "status" => "succeeded" | "failed", "error" => sentence | null}`, pushed
      once, when the estimation is over.

  Both kinds arrive on this one event, and `kind` says which. They are two
  questions about one task, and splitting them into two events would make a
  client subscribe twice to watch one thing.

  There is no progress event and no output event. The estimator answers with
  numbers rather than prose, so there is no stream to pass on, and "it
  started" is not news to the client that started it.

  ## `succeeded` means re-read, not "here are the numbers"

  An estimation of a summary writes onto the work items under it, and those
  are other tasks. So the message says the estimation is over and the client
  re-reads the subtree it is showing. See `RintoPMO.Tasks.Notifier` for why
  nothing tries to broadcast every touched row.
  """

  use RintoPMOWeb, :channel

  alias RintoPMO.Tasks.Notifier
  alias RintoPMO.Utils

  @impl true
  def join("task:" <> task_id, _params, socket) do
    case fetch_task(task_id) do
      {:ok, task} ->
        send(self(), :after_join)
        {:ok, assign(socket, :task, task)}

      :error ->
        {:error, %{reason: "not_found"}}
    end
  end

  @impl true
  def handle_info(:after_join, socket) do
    :ok = Notifier.subscribe(socket.assigns.task.id)
    {:noreply, socket}
  end

  def handle_info({:estimation_finished, result}, socket) do
    push(socket, "estimation", Map.take(result, [:job_id, :kind, :status, :error]))
    {:noreply, socket}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  defp fetch_task(task_id) do
    {:ok, tasks().get_task!(task_id)}
  rescue
    Ecto.NoResultsError -> :error
    Ecto.Query.CastError -> :error
  end

  defp tasks, do: Utils.module(:tasks)
end
