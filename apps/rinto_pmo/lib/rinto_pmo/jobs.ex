defmodule RintoPMO.Jobs do
  @moduledoc """
  Looking up a background job by the id a client was handed.

  Read-only, and deliberately thin: this is not a queue console. It exists so
  that a client which held a job id across a reconnect can find out whether
  the thing it started is still going, without anything having to store a
  second copy of that fact.

  ## Absent means finished, not lost

  A job that is not there has been pruned, and pruning only ever reaches jobs
  that are over. So `:error` from `fetch/1` is not an error the client has to
  handle -- it means "stop waiting", and whatever the job did is already on
  the resource it did it to.

  This is the whole reason nothing else records these attempts: the queue's
  own retention already answers the only question anybody asks.

  ## Three states, not eight

  Oban's states are a queue's business. A client only needs to know whether to
  keep waiting, so they collapse: anything not yet finished is `:running`,
  `completed` is `:succeeded`, and `discarded` or `cancelled` is `:failed`.
  """

  import Ecto.Query

  alias RintoPMO.Repo

  @type status :: :running | :succeeded | :failed

  @type t :: %{
          id: integer(),
          worker: String.t(),
          status: status(),
          error: String.t() | nil,
          inserted_at: DateTime.t()
        }

  @finished %{"completed" => :succeeded, "discarded" => :failed, "cancelled" => :failed}

  @doc """
  The job with this id, as a client needs to see it.

  `:error` when there is no such job, which a caller should read as "it is
  over" rather than as a failure -- see the note above.
  """
  @spec fetch(integer() | String.t()) :: {:ok, t()} | :error
  def fetch(id) do
    with {:ok, id} <- cast_id(id),
         %Oban.Job{} = job <- Repo.one(from(job in Oban.Job, where: job.id == ^id)) do
      {:ok, describe(job)}
    else
      _absent -> :error
    end
  end

  @doc """
  A job row in the same shape `fetch/1` answers with.

  For the endpoint that *starts* work: it is handed the job Oban just
  inserted, and a client should not be able to tell that answer apart from
  what it gets asking about the same id a second later.
  """
  @spec describe(Oban.Job.t()) :: t()
  def describe(%Oban.Job{} = job), do: present(job)

  defp cast_id(id) when is_integer(id), do: {:ok, id}

  defp cast_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {id, ""} -> {:ok, id}
      _not_a_job_id -> :error
    end
  end

  defp cast_id(_id), do: :error

  defp present(%Oban.Job{} = job) do
    %{
      id: job.id,
      worker: job.worker,
      status: Map.get(@finished, job.state, :running),
      error: last_error(job),
      inserted_at: job.inserted_at
    }
  end

  # Whatever the last attempt said, as Oban wrote it down. Formatted for a
  # person reading a log rather than for a UI: a client that was connected
  # already got the sentence over the socket, and this is the copy left for
  # one that was not.
  defp last_error(%Oban.Job{errors: errors}) when is_list(errors) do
    case List.last(errors) do
      %{"error" => error} when is_binary(error) -> error
      _none -> nil
    end
  end

  defp last_error(_job), do: nil
end
