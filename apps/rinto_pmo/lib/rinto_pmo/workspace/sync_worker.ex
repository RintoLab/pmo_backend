defmodule RintoPMO.Workspace.SyncWorker do
  @moduledoc """
  The first clone of a newly registered repository, off the request path.

  A clone of a repository on the public internet takes seconds to tens of
  seconds. Left to happen lazily it would land on whoever first asks a question
  about that project, in the middle of a conversation; and a credential typed in
  wrong would stay invisible until then. Registering a repository is the moment
  somebody is already waiting to hear whether it worked, so that is when it
  happens.

  ## One attempt

  `max_attempts: 1`. The failures this actually sees are a wrong URL, a wrong
  credential and a repository that is not there -- none of which a retry fixes,
  and all of which are already written to `last_sync_error` where whoever
  registered it can read them. A transient one is retried by a person asking
  again, which is `POST .../checkout` with `force`.

  ## Uniqueness is a debounce

  Over `:incomplete` states and `project_repo_id`, so registering and then
  immediately forcing a sync does not clone twice into the same directory. The
  queue serialises checkouts anyway (`RintoPMO.Workspace.Server`); this only
  keeps the second job from waiting to do nothing.
  """

  use Oban.Worker,
    queue: :default,
    max_attempts: 1,
    unique: [keys: [:project_repo_id], period: :infinity, states: :incomplete]

  alias RintoPMO.Workspace

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"project_repo_id" => project_repo_id}}) do
    case Workspace.sync(project_repo_id) do
      :ok -> :ok
      # Recorded on the repository already. Cancelled rather than failed
      # because there is nothing here to try again.
      {:error, reason} -> {:cancel, reason}
    end
  end
end
