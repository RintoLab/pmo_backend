defmodule RintoPMOWeb.V1.ConversationController do
  use RintoPMOWeb, :controller

  alias RintoPMO.Conversations.Sessions
  alias RintoPMO.Utils

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

  def create(conn, params) do
    with {:ok, conversation} <- conversations_context().create_conversation(params) do
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

  # Changing which AI answers has to go through `Sessions`, not straight at the
  # row: a running pi process was told which model to be at startup and cannot
  # be reconfigured, so the switch has to cool the topic to take effect. Writing
  # the row alone would leave it answering as the old actor with nothing saying
  # so.
  #
  # The topic itself survives -- history lives here, and cooling arms the replay
  # that hands it to the new model on the next prompt.
  defp write(conversation, %{"assistant_actor_id" => actor_id} = attrs) do
    with {:ok, conversation} <- Sessions.switch_assistant(conversation, actor_id) do
      case Map.delete(attrs, "assistant_actor_id") do
        empty when empty == %{} -> {:ok, conversation}
        rest -> conversations_context().update_conversation(conversation, rest)
      end
    end
  end

  defp write(conversation, attrs) do
    conversations_context().update_conversation(conversation, attrs)
  end

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
