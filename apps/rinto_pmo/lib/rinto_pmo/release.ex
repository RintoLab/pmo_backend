defmodule RintoPMO.Release do
  @moduledoc """
  The commands a deployment needs, for a release that has no Mix in it.

      bin/rinto_pmo eval 'RintoPMO.Release.migrate()'
      bin/rinto_pmo eval 'RintoPMO.Release.setup_human("Kenton")'
      bin/rinto_pmo eval 'RintoPMO.Release.rollback(RintoPMO.Repo, 20260813035152)'

  `mix ecto.migrate` is a Mix task, and Mix is a build tool that is not shipped
  in a release. These do the same work through `Ecto.Migrator` instead.

  ## Why `eval` rather than a `start` hook

  Migrating on boot would run once per node and race itself the first time
  there are two, and a migration that fails would take the application down
  with it rather than stopping the deployment. `eval` starts the repository,
  does the one thing, and exits -- so a deploy script can refuse to restart the
  service when it fails.
  """

  @app :rinto_pmo

  @doc """
  Runs every migration that has not been run.

  Creating the database is deliberately not here. It is done once, by hand, on
  the database server -- which keeps `CREATEDB` out of the role this connects
  with. A database that does not exist fails here, on `schema_migrations`.
  """
  @spec migrate() :: :ok
  def migrate do
    load_app()

    for repo <- repos() do
      {:ok, _result, _apps} =
        Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
    end

    :ok
  end

  @doc """
  Rolls `repo` back to `version`.
  """
  @spec rollback(module(), integer()) :: :ok
  def rollback(repo, version) do
    load_app()

    {:ok, _result, _apps} =
      Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :down, to: version))

    :ok
  end

  @doc """
  Creates the human this installation belongs to, and the default project.

  The release counterpart of `mix rinto.actors.setup_human`, and the same work:
  see `RintoPMO.Setup`. Run once against a fresh database -- a server whose
  `RINTO_TOKEN` is right but which has no human answers every request with
  `human_actor_missing`.
  """
  @spec setup_human(String.t() | nil) :: :ok
  def setup_human(name \\ nil) do
    load_app()

    {:ok, _result, _apps} =
      Ecto.Migrator.with_repo(RintoPMO.Repo, fn _repo ->
        IO.puts(RintoPMO.Setup.describe(RintoPMO.Setup.ensure_default_project()))
        IO.puts(RintoPMO.Setup.describe(RintoPMO.Setup.ensure_default_assistant()))
        IO.puts(RintoPMO.Setup.describe(RintoPMO.Setup.ensure_human(name)))
      end)

    :ok
  end

  defp repos do
    Application.fetch_env!(@app, :ecto_repos)
  end

  # `:ssl` is started even though nothing here obviously needs it: a
  # `DATABASE_URL` with TLS on it -- which is most managed Postgres -- fails
  # inside Postgrex with an error that says nothing about a missing
  # application. This is what `mix phx.gen.release` generates, for that reason.
  #
  # The application itself is only loaded, not started:
  # `Ecto.Migrator.with_repo/2` starts the repository and what it needs, and
  # nothing here wants the endpoint listening or the agent supervisor running.
  defp load_app do
    Application.ensure_all_started(:ssl)
    Application.ensure_loaded(@app)
  end
end
