defmodule Mix.Tasks.Rinto.Workspace.Sync do
  @shortdoc "Queues a clone or fetch for every registered repository"

  @moduledoc """
  Brings every repository in `project_repos` into the workspace.

      mix rinto.workspace.sync

  There are two moments for this. The first is turning the workspace on: every
  repository registered before `RINTO_WORKSPACE_ROOT` existed has never been
  cloned, and nothing would clone it until somebody asked about that project's
  code -- which would be a minute of waiting inside a conversation, and a wrong
  credential discovered there rather than here.

  The second is after moving or losing the workspace directory. Everything in it
  is derived: mirrors, worktrees, all of it can be thrown away and this puts it
  back.

  Not a repair for staleness. A repository that is merely out of date is brought
  up to date by the next `POST /projects/:slug/repos/:id/checkout`, which is
  what every read goes through anyway.

  Queues rather than clones: the jobs run one at a time behind
  `RintoPMO.Workspace.Server`, so this returns immediately and a large first
  clone does not hold the terminal. Safe to run repeatedly -- the worker
  deduplicates over repositories already queued.
  """

  use Mix.Task

  import Ecto.Query

  alias RintoPMO.Projects.ProjectRepo
  alias RintoPMO.Repo
  alias RintoPMO.Workspace
  alias RintoPMO.Workspace.SyncWorker

  @impl Mix.Task
  def run(_argv) do
    Mix.Task.run("app.start")

    if Workspace.configured?() do
      queue(Repo.all(from repo in ProjectRepo, select: repo.id))
    else
      Mix.shell().error(
        "no workspace is configured: set RINTO_WORKSPACE_ROOT, or this server keeps no working copies"
      )
    end
  end

  defp queue([]) do
    Mix.shell().info("no repositories are registered")
  end

  defp queue(ids) do
    queued =
      Enum.count(ids, fn id ->
        case Oban.insert(SyncWorker.new(%{project_repo_id: id})) do
          {:ok, %Oban.Job{conflict?: true}} -> false
          {:ok, _job} -> true
          {:error, _reason} -> false
        end
      end)

    Mix.shell().info("queued #{queued} of #{length(ids)} repositories")
  end
end
