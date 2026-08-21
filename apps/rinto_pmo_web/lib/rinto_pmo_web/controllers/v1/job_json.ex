defmodule RintoPMOWeb.V1.JobJSON do
  @moduledoc """
  A background job, as the client that started it needs to see it.

  Deliberately not the job row. `args` and `meta` are the queue's business and
  can hold anything a worker felt like putting there, so nothing here echoes
  them back; what a client gets is the id it already had, what kind of work it
  was, and whether to keep waiting.
  """

  def show(%{job: job}), do: %{data: data(job)}

  @doc """
  The job as every caller sees it.
  """
  def data(job) do
    %{
      id: job.id,
      worker: job.worker,
      status: job.status,
      error: job.error,
      inserted_at: job.inserted_at
    }
  end
end
