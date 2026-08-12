defmodule Mix.Tasks.Rinto.Actors.SetupHuman do
  @shortdoc "Creates the human actor and the default project, and prints the API token"

  @moduledoc """
  Sets this installation up for the one person who operates it.

      mix rinto.actors.setup_human [--name NAME] [--actor-id ID] [--rotate]

  Does three things, all of them idempotent:

    * creates the human actor if there is not one
    * issues it a token if it has none, and prints the token
    * creates the default project, `personal`, if it is not there

  Everything the API serves is behind that token (see
  `RintoPMOWeb.Plugs.ActorToken`), so this is the first thing to run against a
  fresh database and the only way to get in.

  ## Why the project is set up here too

  A document created without a project is filed in `personal` rather than left
  belonging to nothing (see `RintoPMO.Documents.create_document/1`), so an
  installation without that project cannot take the most ordinary write there
  is. That makes it part of what "set up" means, not a separate errand -- and
  the person who has just been handed a token is the one it belongs to.

  ## Running it twice changes nothing

  A second run finds the human already there, finds the token already issued,
  and prints the same token again. That is the point: the common reason to run
  this is having closed the terminal the token was printed in, and answering
  that by rotating would log out the editor and the CLI to solve a problem
  neither of them had.

  Use `--rotate` to deliberately replace the token. The old one stops working
  immediately and any open WebSocket carrying it is disconnected, which is what
  makes it worth having.

  ## It refuses to guess between two people

  Several human actors is not a state this task will pick a winner in --
  issuing a token to the wrong one attributes a person's decisions to somebody
  else. It names the candidates and stops, and `--actor-id` is how you answer
  it. That flag is the only way out of the tie: `PUT /api/v1/actors/me/token`
  cannot help, because it needs the token you are trying to get.

  ## Options

    * `--name` -- the actor's name on creation, defaulting to `$USER`. Ignored
      when the human already exists; renaming is `PATCH /api/v1/actors/{id}`
    * `--actor-id` -- issue to this actor rather than looking for the only
      human. Refuses an AI: a token is a person's
    * `--rotate` -- issue a new token even though there is one
  """

  use Mix.Task

  alias RintoPMO.Actors
  alias RintoPMO.Projects

  @impl Mix.Task
  def run(argv) do
    {opts, _rest, _invalid} =
      OptionParser.parse(argv, strict: [name: :string, actor_id: :string, rotate: :boolean])

    Mix.Task.run("app.start")

    ensure_default_project()

    case find(opts[:actor_id]) do
      {:ok, human} -> ensure_token(human, opts[:rotate] == true)
      {:error, :human_actor_not_found} -> create(opts[:name] || default_name())
      {:error, :human_actor_ambiguous, details} -> ambiguous(details)
    end
  end

  # Run before the actor, so that a database with several humans still ends up
  # with somewhere to put documents: the tie is a question about identity, and
  # it should not also hold the project hostage.
  defp ensure_default_project do
    case Projects.get_default_project() do
      %{slug: slug, name: name} ->
        Mix.shell().info("default project #{name} (#{slug}) is already there")

      nil ->
        slug = Projects.default_slug()

        case Projects.create_project(%{
               name: "Personal",
               slug: slug,
               description: "Notes and documents that belong to no particular project."
             }) do
          {:ok, project} ->
            Mix.shell().info("created default project #{project.name} (#{slug})")

          {:error, changeset} ->
            Mix.raise("could not create the default project: #{inspect(changeset.errors)}")
        end
    end
  end

  defp find(nil), do: Actors.get_unique_human()

  defp find(actor_id) do
    case Actors.get_actor!(actor_id) do
      %{kind: :human} = human -> {:ok, human}
      %{kind: :ai, name: name} -> Mix.raise("#{name} is an AI actor, and a token is a person's")
    end
  rescue
    Ecto.NoResultsError -> Mix.raise("no actor with id #{actor_id}")
    Ecto.Query.CastError -> Mix.raise("#{actor_id} is not an actor id")
  end

  defp create(name) do
    case Actors.create_actor(%{kind: :human, name: name}) do
      {:ok, human} ->
        Mix.shell().info("created human actor #{human.name} (#{human.id})")
        issue(human)

      {:error, changeset} ->
        Mix.raise("could not create the human actor: #{inspect(changeset.errors)}")
    end
  end

  defp ensure_token(%{token: nil} = human, _rotate) do
    Mix.shell().info("found human actor #{human.name} (#{human.id}), which had no token")
    issue(human)
  end

  defp ensure_token(human, true) do
    Mix.shell().info("rotating the token of #{human.name} (#{human.id})")
    issue(human)
  end

  defp ensure_token(human, false) do
    Mix.shell().info("human actor #{human.name} (#{human.id}) already has a token")
    report(human.token)
  end

  defp issue(human) do
    case Actors.issue_token(human) do
      {:ok, human} -> report(human.token)
      {:error, changeset} -> Mix.raise("could not issue a token: #{inspect(changeset.errors)}")
    end
  end

  @spec ambiguous(map()) :: no_return()
  defp ambiguous(%{actor_ids: ids}) do
    Mix.raise("""
    this system has #{length(ids)} human actors and will not choose between them:

    #{Enum.map_join(ids, "\n", &"  mix rinto.actors.setup_human --actor-id #{&1}")}

    Run one of the above, or remove the rows that should not be there.
    """)
  end

  # Printed rather than written anywhere: the token's only home is wherever the
  # person putting it into a client keeps it, and a copy left in the repository
  # is a copy nobody remembers to delete.
  defp report(token) do
    Mix.shell().info("""

    token: #{token}

    Every API call carries it:

      curl -H 'Authorization: Bearer #{token}' http://localhost:4000/api/v1/actors/me

    The CLI stores it once:

      rinto-pmo config init --api http://localhost:4000/api/v1 --token #{token}
    """)
  end

  defp default_name, do: System.get_env("USER") || "Me"
end
