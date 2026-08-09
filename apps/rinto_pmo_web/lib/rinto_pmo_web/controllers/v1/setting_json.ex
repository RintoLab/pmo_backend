defmodule RintoPMOWeb.V1.SettingJSON do
  alias RintoPMO.Actors.Actor
  alias RintoPMOWeb.V1.ActorJSON

  def index(%{settings: settings}) do
    %{data: Map.new(settings, fn {key, actor} -> {key, actor_data(actor)} end)}
  end

  # The actor is rendered whole rather than as an id, because the one question
  # asked of this endpoint is "who is naming my topics" and a client should not
  # have to fetch the actor list to answer it.
  defp actor_data(%Actor{} = actor), do: ActorJSON.data(actor)
  defp actor_data(nil), do: nil
end
