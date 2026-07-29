defmodule RintoPMOWeb.V1.ActorController do
  use RintoPMOWeb, :controller

  alias RintoPMO.Utils

  action_fallback RintoPMOWeb.FallbackController

  def index(conn, _params) do
    actors = actor_context().list_actors()

    render(conn, :index, actors: actors)
  end

  def show(conn, %{"id" => id}) do
    actor = actor_context().get_actor!(id)

    render(conn, :show, actor: actor)
  end

  def create(conn, %{"actor" => actor_params}) do
    with {:ok, actor} <- actor_context().create_actor(actor_params) do
      conn
      |> put_status(:created)
      |> render(:show, actor: actor)
    end
  end

  def update(conn, %{"id" => id, "actor" => actor_params}) do
    context = actor_context()
    actor = context.get_actor!(id)

    with {:ok, actor} <- context.update_actor(actor, actor_params) do
      render(conn, :show, actor: actor)
    end
  end

  defp actor_context, do: Utils.module(:actors)
end
