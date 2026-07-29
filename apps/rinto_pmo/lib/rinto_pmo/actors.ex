defmodule RintoPMO.Actors do
  @moduledoc """
  The context for human participants and AI personas.
  """

  use RintoPMO, :context

  alias RintoPMO.Actors.Actor

  @doc """
  Lists all actors.
  """
  def list_actors do
    Actor
    |> order_by([actor], asc: actor.name)
    |> Repo.all()
  end

  @doc """
  Fetches an actor by id, raising when it does not exist.
  """
  def get_actor!(id), do: Repo.get!(Actor, id)

  @doc """
  Creates an actor.
  """
  def create_actor(attrs) do
    attrs
    |> Actor.changeset()
    |> Repo.insert()
  end

  @doc """
  Updates an actor.
  """
  def update_actor(%Actor{} = actor, attrs) do
    actor
    |> Actor.changeset(attrs)
    |> Repo.update()
  end
end
