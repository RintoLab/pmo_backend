defmodule RintoPMO.Workspace.Server do
  @moduledoc """
  The queue that keeps two checkouts out of the same directory.

  Git is not safe to run twice at once in one repository -- `index.lock` is the
  polite failure, and a `reset --hard` landing while another process reads the
  tree is the impolite one. A mailbox is the whole mechanism: work happens in
  this process, so requests wait their turn without anyone taking a lock.

  ## One queue for everything, not one per repository

  A slow clone therefore delays a checkout of an unrelated repository. That is
  the accepted cost: an installation has a handful of repositories, each git
  call is bounded by its own timeout, and a per-repository registry would be
  more moving parts than the contention it removes. Split it when some
  repository is big enough to make the wait real.

  ## Started even when there is no workspace

  Configuration is read per call rather than at boot, so an installation with
  no `:root` runs this process and answers `{:error, :not_configured}` from it.
  Otherwise turning the feature on would mean a restart.
  """

  use GenServer

  alias RintoPMO.Projects.Project
  alias RintoPMO.Projects.ProjectRepo
  alias RintoPMO.Workspace

  # Longer than the longest git call this can make, plus room to sit behind one
  # other clone. A caller that waits longer than this is queued behind more work
  # than an interactive request should wait for.
  @call_timeout :timer.minutes(5)

  @doc false
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  Runs `RintoPMO.Workspace.perform_checkout/3` in this process.
  """
  @spec checkout(Project.t(), ProjectRepo.t(), [Workspace.opt()]) ::
          {:ok, Workspace.checkout()} | {:error, Workspace.error()}
  def checkout(%Project{} = project, %ProjectRepo{} = repo, opts \\ []) do
    GenServer.call(__MODULE__, {:checkout, project, repo, opts}, @call_timeout)
  end

  @impl true
  def init(_opts), do: {:ok, %{}}

  @impl true
  def handle_call({:checkout, project, repo, opts}, _from, state) do
    {:reply, Workspace.perform_checkout(project, repo, opts), state}
  end
end
