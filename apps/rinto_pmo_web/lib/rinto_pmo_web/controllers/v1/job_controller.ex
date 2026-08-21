defmodule RintoPMOWeb.V1.JobController do
  use RintoPMOWeb, :controller

  alias RintoPMO.Jobs

  @doc """
  Whether the job this id names is still going.

  The way back for a client that started something, lost its connection, and
  came back holding an id. The socket is the normal way to find out -- see
  `RintoPMOWeb.TaskChannel` -- and this is what to ask when the message went
  out while nobody was listening.

  `404` means the job has been pruned, and pruning only reaches jobs that are
  over: the right thing to do with it is to stop waiting and re-read the
  resource, not to treat it as an error.
  """
  def show(conn, %{"id" => id}) do
    with {:ok, job} <- fetch(id) do
      render(conn, :show, job: job)
    end
  end

  defp fetch(id) do
    case Jobs.fetch(id) do
      {:ok, job} -> {:ok, job}
      :error -> {:error, :not_found}
    end
  end
end
