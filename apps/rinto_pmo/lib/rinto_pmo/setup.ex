defmodule RintoPMO.Setup do
  @moduledoc """
  What "set up" means for a database nobody has used yet.

  Three things, none of which the token can supply: somebody for requests to be
  answered as, somewhere for a document created without a project to go, and a
  name for what an AI writes from a plain chat to be signed with. A server with
  a perfectly good `RINTO_TOKEN` and none of these refuses every call with
  `human_actor_missing`.

  ## Why it is not a Mix task

  It is run from two places that have nothing in common. A developer runs
  `mix rinto.actors.setup_human`; a deployment runs
  `RintoPMO.Release.setup_human/1`, in a release, which has no Mix in it at
  all. So the work lives here and the callers print, with `describe/1` shared
  between them -- two entry points saying different things about the same
  outcome is how one of them ends up lying.
  """

  alias RintoPMO.Actors
  alias RintoPMO.Actors.Actor
  alias RintoPMO.Projects
  alias RintoPMO.Projects.Project
  alias RintoPMO.Repo

  @default_assistant_name "AI"

  @type project_outcome ::
          {:created, Project.t()} | {:present, Project.t()} | {:error, Ecto.Changeset.t()}

  @type human_outcome ::
          {:created, Actor.t()}
          | {:present, Actor.t()}
          | {:several, pos_integer(), Actor.t()}
          | {:error, Ecto.Changeset.t()}

  # Tagged, because an actor outcome would otherwise be indistinguishable from
  # the human's and `describe/1` would print the wrong sentence about it.
  @type assistant_outcome ::
          {:created, :assistant, Actor.t()}
          | {:present, :assistant, Actor.t()}
          | {:error, Ecto.Changeset.t()}

  @doc """
  Creates the default project, `personal`, unless it is already there.

  Run before the human, so that a database this cannot pick a person in still
  ends up with somewhere to put documents.
  """
  @spec ensure_default_project() :: project_outcome()
  def ensure_default_project do
    case Projects.get_default_project() do
      %Project{} = project ->
        {:present, project}

      nil ->
        Projects.create_project(%{
          name: "Personal",
          slug: Projects.default_slug(),
          description: "Notes and documents that belong to no particular project."
        })
        |> case do
          {:ok, project} -> {:created, project}
          {:error, changeset} -> {:error, changeset}
        end
    end
  end

  @doc """
  Creates the human this installation belongs to, unless there is one.

  Several humans is reported rather than refused. There is a single token, so
  there is a single caller, and `RintoPMO.Actors.get_owner/0` already answers
  which of them that is -- the outcome names them so that nobody has to guess.
  """
  @spec ensure_human(String.t() | nil) :: human_outcome()
  def ensure_human(name \\ nil) do
    case Actors.get_unique_human() do
      {:ok, human} ->
        {:present, human}

      {:error, :human_actor_not_found} ->
        create_human(name || default_name())

      {:error, :human_actor_ambiguous, %{count: count}} ->
        {:several, count, Actors.get_owner()}
    end
  end

  @doc """
  Creates the actor a plain chat's writing is signed with, unless it is there.

  It carries no model configuration and never will: what wrote the text is
  whichever provider and model the person had selected, and this row exists to
  answer the coarser question a document actually needs answered -- a model
  wrote this, not a person. See `RintoPMO.Actors.Actor`.

  Renaming it later is ordinary: the name is what a reader sees beside a block,
  and `PATCH /actors/{id}` is how somebody changes it.
  """
  @spec ensure_default_assistant() :: assistant_outcome()
  def ensure_default_assistant do
    case Actors.get_default_assistant() do
      %Actor{} = assistant ->
        {:present, :assistant, assistant}

      nil ->
        %{
          name: @default_assistant_name,
          description: "What an AI writes from a plain chat is signed with this."
        }
        |> Actor.default_changeset()
        |> Repo.insert()
        |> case do
          {:ok, assistant} -> {:created, :assistant, assistant}
          {:error, changeset} -> {:error, changeset}
        end
    end
  end

  @doc """
  The name a human is created with when the caller names nobody.

  `RINTO_OWNER_NAME` first, because the caller that names nobody is usually the
  deploy: it runs `RintoPMO.Release.setup_human/1` on every deploy, and taking
  the name from the environment is what keeps a shell from having to interpolate
  it into an Elixir string. `$USER` behind it, for `mix rinto.actors.setup_human`
  on somebody's own machine.
  """
  @spec default_name() :: String.t()
  def default_name do
    System.get_env("RINTO_OWNER_NAME") || System.get_env("USER") || "Me"
  end

  @doc """
  One line saying what happened, for whichever of the two callers is printing.
  """
  @spec describe(project_outcome() | human_outcome() | assistant_outcome()) :: String.t()
  def describe({:present, %Project{name: name, slug: slug}}),
    do: "default project #{name} (#{slug}) is already there"

  def describe({:created, %Project{name: name, slug: slug}}),
    do: "created default project #{name} (#{slug})"

  def describe({:present, :assistant, %Actor{} = assistant}),
    do: "default assistant #{assistant.name} (#{assistant.id}) is already there"

  def describe({:created, :assistant, %Actor{} = assistant}),
    do: "created default assistant #{assistant.name} (#{assistant.id})"

  def describe({:present, %Actor{} = human}),
    do: "human actor #{human.name} (#{human.id}) is already there"

  def describe({:created, %Actor{} = human}),
    do: "created human actor #{human.name} (#{human.id})"

  def describe({:several, count, %Actor{} = owner}) do
    "this system has #{count} human actors; requests are answered as the " <>
      "earliest of them, #{owner.name} (#{owner.id})"
  end

  def describe({:error, %Ecto.Changeset{} = changeset}),
    do: "failed: #{inspect(changeset.errors)}"

  defp create_human(name) do
    case Actors.create_actor(%{kind: :human, name: name}) do
      {:ok, human} -> {:created, human}
      {:error, changeset} -> {:error, changeset}
    end
  end
end
