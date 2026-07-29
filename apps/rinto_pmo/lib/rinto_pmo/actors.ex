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
