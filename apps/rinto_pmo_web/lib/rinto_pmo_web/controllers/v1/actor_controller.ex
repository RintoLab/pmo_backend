defmodule RintoPMOWeb.V1.ActorController do
  use RintoPMOWeb, :controller

  alias RintoPMO.Utils
  alias RintoPMOWeb.Plugs.ActorToken

  def index(conn, _params) do
    actors = actor_context().list_actors()

    render(conn, :index, actors: actors)
  end

  @doc """
  The actor the request's token belongs to.

  A client calls this once at startup to learn its own id, which it then has no
  further use for: nothing it sends says who it is any more.
  """
  def me(conn, _params) do
    render(conn, :show, actor: ActorToken.current_actor!(conn))
  end

  def show(conn, %{"id" => id}) do
    actor = actor_context().get_actor!(id)

    render(conn, :show, actor: actor)
  end

  def create(conn, params) do
    with {:ok, actor} <- actor_context().create_actor(params) do
      conn
      |> put_status(:created)
      |> render(:show, actor: actor)
    end
  end

  def update(conn, %{"id" => id} = params) do
    context = actor_context()
    actor = context.get_actor!(id)
    actor_params = Map.delete(params, "id")

    with {:ok, actor} <- context.update_actor(actor, actor_params) do
      render(conn, :show, actor: actor)
    end
  end

  defp actor_context, do: Utils.module(:actors)
end
