defmodule RintoPMOWeb.V1.ConversationController do
  use RintoPMOWeb, :controller

  alias RintoPMO.Conversations.Sessions
  alias RintoPMO.Utils
  alias RintoPMOWeb.Plugs.ActorToken

  def index(conn, params) do
    with {:ok, filter} <- conversation_filter(params) do
      conversations = conversations_context().list_conversations(filter)
      render(conn, :index, conversations: conversations)
    end
  end

  def show(conn, %{"id" => id}) do
    conversation = conversations_context().get_conversation!(id)
    render(conn, :show, conversation: conversation)
  end

  # `actor_id` here is who started the topic, which is whoever is calling.
  # How the assistant answers stays in the body: either a fixed
  # `assistant_actor_id`, or a plain chat's provider/model/thinking selection.
  def create(conn, params) do
    attrs = Map.put(params, "actor_id", ActorToken.current_actor!(conn).id)

    with {:ok, conversation} <- conversations_context().create_conversation(attrs) do
      conn
      |> put_status(:created)
      |> render(:show, conversation: conversation)
    end
  end

  def update(conn, %{"id" => id} = params) do
    context = conversations_context()
    conversation = context.get_conversation!(id)
    attrs = Map.delete(params, "id")

    with {:ok, conversation} <- write(conversation, attrs) do
      render(conn, :show, conversation: conversation)
    end
  end

  # Changing either an actor assistant or a plain chat's model configuration has
  # to go through `Sessions`, not straight at the row: a running pi process was
  # told its configuration at startup and cannot be reconfigured, so the switch
  # has to cool the topic to take effect.
  #
  # The topic itself survives -- history lives here, and cooling arms the replay
  # that hands it to the new model on the next prompt.
  defp write(conversation, attrs) do
    if Enum.any?(assistant_configuration_keys(), &Map.has_key?(attrs, &1)) do
      Sessions.switch_configuration(conversation, attrs)
    else
      conversations_context().update_conversation(conversation, attrs)
    end
  end

  defp assistant_configuration_keys,
    do: ~w(mode assistant_actor_id provider model thinking_level)

  @doc """
  Cools a topic: closes its pi process and keeps everything it said.

  There is no delete. A conversation is the only thing that can answer why a
  passage reads the way it does, so it is kept permanently and merely stops
  costing a process.
  """
  def close(conn, %{"id" => id}) do
    context = conversations_context()
    conversation = context.get_conversation!(id)

    with {:ok, conversation} <- Sessions.cool(conversation) do
      render(conn, :show, conversation: conversation)
    end
  end

  defp conversation_filter(params) do
    case Map.get(params, "actor_id") do
      nil ->
        {:ok, %{}}

      value ->
        case UUIDv7.cast(value) do
          {:ok, actor_id} -> {:ok, %{actor_id: actor_id}}
          :error -> {:error, :bad_request, %{"actor_id" => ["is invalid"]}}
        end
    end
  end

  defp conversations_context, do: Utils.module(:conversations)
end
