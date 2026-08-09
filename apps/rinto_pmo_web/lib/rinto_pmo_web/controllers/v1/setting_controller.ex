defmodule RintoPMOWeb.V1.SettingController do
  @moduledoc """
  Who does the jobs that belong to the system rather than to a topic.

  Every setting is an actor, so both responses carry the whole set: a client
  replaces what it is holding rather than merging a patch into it.
  """

  use RintoPMOWeb, :controller

  alias RintoPMO.Settings

  def index(conn, _params) do
    render(conn, :index, settings: Settings.list_settings())
  end

  @doc """
  Puts an actor in a role, or empties it with `"actor_id": null`.

  A `PUT` rather than a `POST` under the actor: the role holds one actor, and
  naming a new one is replacing the old, not adding to it. An unknown role is a
  404 -- roles are defined by the system, not created by a client.
  """
  def update(conn, %{"key" => key} = params) do
    with {:ok, settings} <- Settings.put_actor(key, Map.get(params, "actor_id")) do
      render(conn, :index, settings: settings)
    end
  end
end
