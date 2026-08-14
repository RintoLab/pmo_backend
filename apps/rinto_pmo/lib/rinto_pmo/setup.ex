defmodule RintoPMO.Setup do
  @moduledoc """
  What "set up" means for a database nobody has used yet.

  Two things, neither of which the token can supply: somebody for requests to
  be answered as, and somewhere for a document created without a project to go.
  A server with a perfectly good `RINTO_TOKEN` and neither of these refuses
  every call with `human_actor_missing`.

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

  @type project_outcome ::
          {:created, Project.t()} | {:present, Project.t()} | {:error, Ecto.Changeset.t()}

  @type human_outcome ::
          {:created, Actor.t()}
          | {:present, Actor.t()}
          | {:several, pos_integer(), Actor.t()}
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
  The name a human is created with when the caller names nobody.
  """
  @spec default_name() :: String.t()
  def default_name, do: System.get_env("USER") || "Me"

  @doc """
  One line saying what happened, for whichever of the two callers is printing.
  """
  @spec describe(project_outcome() | human_outcome()) :: String.t()
  def describe({:present, %Project{name: name, slug: slug}}),
    do: "default project #{name} (#{slug}) is already there"

  def describe({:created, %Project{name: name, slug: slug}}),
    do: "created default project #{name} (#{slug})"

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
