defmodule RintoPMO.Tasks.Notifier do
  @moduledoc """
  Says that an estimation is over, to everyone watching that task.

  Built on the same PubSub as `RintoPMO.Documents.Notifier`, and for the same
  reason: the work happens somewhere other than the connection that asked for
  it. The job may outlive the request, and there may be several connections --
  another tab, the board beside it.

  ## Only the end

  Unlike a decomposition, an estimation announces nothing on the way. Queued
  and started are not states anybody has to be told about: the client that
  clicked already knows, because it holds the job id it was answered with, and
  the client that did not click has nothing to show for "somebody else is
  thinking" that it will not learn from the result a moment later.

  So there is one message, sent as the last thing the job does:

    * `{:estimation_finished, result}` -- a map of `job_id`, `task_id`, `kind`,
      `status` (`:succeeded` or `:failed`), and `error`, which is a sentence
      when the status is `:failed` and `nil` otherwise.

  ## Nothing is stored, and that is the whole design

  There is no attempt row. An estimation is a helper path for somebody looking
  at an empty field, and what it leaves behind is the numbers on the tasks --
  which is the thing a client re-reads anyway. A record of the *asking* would
  be a second copy of state that only the queue needs.

  A client that missed this message because it was not connected has two ways
  back: re-read the task and see whether the field filled in, or ask
  `RintoPMO.Jobs.fetch/1` about the job id it kept. A job that is gone is a
  job whose answer is already on the task.

  ## What `:succeeded` does not carry

  An estimation of a summary writes onto the work items *under* it, which are
  other tasks on other topics. So the message says only that it finished; a
  client that wants the numbers re-reads the subtree. Broadcasting every
  touched row would mean a message per task on a topic nobody joined.
  """

  @pubsub RintoPMO.PubSub

  @type status :: :succeeded | :failed

  @type result :: %{
          job_id: integer(),
          task_id: UUIDv7.t(),
          kind: :difficulty | :time,
          status: status(),
          error: String.t() | nil
        }

  @doc """
  The PubSub topic carrying one task's activity.

  Deliberately equal to the channel topic clients join, so there is one name
  for "this task" rather than two that have to be kept in step.
  """
  @spec topic(UUIDv7.t()) :: String.t()
  def topic(task_id) when is_binary(task_id), do: "task:" <> task_id

  @doc """
  Subscribes the calling process to a task's activity.
  """
  @spec subscribe(UUIDv7.t(), atom()) :: :ok | {:error, term()}
  def subscribe(task_id, pubsub \\ @pubsub) do
    Phoenix.PubSub.subscribe(pubsub, topic(task_id))
  end

  @doc """
  Announces that an estimation is over, and how it went.
  """
  @spec broadcast_estimation(
          integer(),
          UUIDv7.t(),
          :difficulty | :time,
          status(),
          String.t() | nil,
          atom()
        ) :: :ok | {:error, term()}
  def broadcast_estimation(job_id, task_id, kind, status, error, pubsub \\ @pubsub) do
    result = %{
      job_id: job_id,
      task_id: task_id,
      kind: kind,
      status: status,
      error: error
    }

    Phoenix.PubSub.broadcast(pubsub, topic(task_id), {:estimation_finished, result})
  end
end
