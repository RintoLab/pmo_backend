defmodule RintoPMO.Actors do
  @moduledoc """
  The context for human participants and AI personas.
  """

  use RintoPMO, :context

  alias RintoPMO.Actors.Actor

  defmodule Behaviour do
    @moduledoc false

    alias RintoPMO.Actors.Actor

    @callback list_actors() :: [Actor.t()]
    @callback get_unique_human() ::
                {:ok, Actor.t()}
                | {:error, :human_actor_not_found}
                | {:error, :human_actor_ambiguous, map()}
    @callback get_actor!(UUIDv7.t()) :: Actor.t()
    @callback create_actor(map()) :: {:ok, Actor.t()} | {:error, Ecto.Changeset.t()}
    @callback update_actor(Actor.t(), map()) ::
                {:ok, Actor.t()} | {:error, Ecto.Changeset.t()}
  end

  @behaviour Behaviour

  @doc """
  Lists all actors.
  """
  @impl true
  def list_actors do
    Actor
    |> order_by([actor], asc: actor.name)
    |> Repo.all()
  end

  @doc """
  Fetches the system's only human participant.

  This is the pre-authentication identity used by local clients. Refusing zero
  or several humans is deliberate: choosing an arbitrary person would
  attribute documents and completed work to the wrong user.
  """
  @impl true
  def get_unique_human do
    humans =
      Actor
      |> where([actor], actor.kind == :human)
      |> order_by([actor], asc: actor.inserted_at)
      |> Repo.all()

    case humans do
      [human] ->
        {:ok, human}

      [] ->
        {:error, :human_actor_not_found}

      several ->
        {:error, :human_actor_ambiguous,
         %{actor_ids: Enum.map(several, & &1.id), count: length(several)}}
    end
  end

  @doc """
  Fetches an actor by id, raising when it does not exist.
  """
  @impl true
  def get_actor!(id), do: Repo.get!(Actor, id)

  @doc """
  Creates an actor.
  """
  @impl true
  def create_actor(attrs) do
    attrs
    |> Actor.changeset()
    |> Repo.insert()
  end

  @doc """
  Updates an actor.
  """
  @impl true
  def update_actor(%Actor{} = actor, attrs) do
    actor
    |> Actor.changeset(attrs)
    |> Repo.update()
  end
end
