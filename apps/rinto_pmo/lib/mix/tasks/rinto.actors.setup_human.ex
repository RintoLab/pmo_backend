defmodule Mix.Tasks.Rinto.Actors.SetupHuman do
  @shortdoc "Creates the human actor and the default project"

  @moduledoc """
  Sets this installation up for the one person who operates it.

      mix rinto.actors.setup_human [--name NAME]

  Does two things, both idempotent:

    * creates the human actor if there is not one
    * creates the default project, `personal`, if it is not there

  ## It issues nothing

  The token is not this task's business, and never appears in its output. It is
  agreed in advance and configured on both ends -- `RINTO_TOKEN` for the
  server, a config file for each client that calls it (`rinto-pmo config init`)
  -- because there is no way to distribute a token from here: every client
  keeps its own copy, so a value this task invented would be a fourth thing to
  copy around rather than a source anybody reads. See `RintoPMO.Actors`.

  What this task does is the other half of being set up. The token says a
  request may be answered; the human actor is who it is answered *as*, and
  without one the server refuses every call with `human_actor_missing`.

  ## Why the project is set up here too

  A document created without a project is filed in `personal` rather than left
  belonging to nothing (see `RintoPMO.Documents.create_document/1`), so an
  installation without that project cannot take the most ordinary write there
  is. That makes it part of what "set up" means, not a separate errand -- and
  the person who has just been created is who it belongs to.

  ## Running it twice changes nothing

  A second run finds the human already there and says so. Several humans is not
  an error either, only worth mentioning: one of them is the caller -- the
  earliest, per `RintoPMO.Actors.get_owner/0` -- and the rest are colleagues on
  the record. There is a single token, so there is a single caller, and no tie
  for this task to break.

  ## Options

    * `--name` -- the actor's name on creation, defaulting to `$USER`. Ignored
      when the human already exists; renaming is `PATCH /api/v1/actors/{id}`
  """

  use Mix.Task

  alias RintoPMO.Actors
  alias RintoPMO.Setup

  @impl Mix.Task
  def run(argv) do
    {opts, _rest, _invalid} = OptionParser.parse(argv, strict: [name: :string])

    Mix.Task.run("app.start")

    # The project first, so that a database this cannot pick a person in still
    # ends up with somewhere to put documents.
    report(Setup.ensure_default_project())
    report(Setup.ensure_default_assistant())
    report(Setup.ensure_human(opts[:name]))
    report_token()
  end

  defp report({:error, changeset}) do
    Mix.raise("setup failed: #{inspect(changeset.errors)}")
  end

  defp report(outcome), do: Mix.shell().info(Setup.describe(outcome))

  # Says where the token comes from rather than printing one, because this task
  # has none to print. A server started without `RINTO_TOKEN` refuses every
  # request, and finding that out here is cheaper than finding it out from a
  # 401.
  defp report_token do
    case Actors.configured_token() do
      nil ->
        Mix.shell().info("""

        This server has no RINTO_TOKEN, so it will answer nothing. Choose a \
        token, start the server with it, and give the same value to each client:

          RINTO_TOKEN=<token> mix phx.server
          rinto-pmo config init --api http://localhost:4000/api/v1
        """)

      _configured ->
        Mix.shell().info("""

        RINTO_TOKEN is configured. Every API call carries it:

          curl -H 'Authorization: Bearer <token>' http://localhost:4000/api/v1/actors/me
        """)
    end
  end
end
