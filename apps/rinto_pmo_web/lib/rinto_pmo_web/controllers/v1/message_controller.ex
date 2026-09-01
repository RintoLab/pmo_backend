defmodule RintoPMOWeb.V1.MessageController do
  use RintoPMOWeb, :controller

  alias RintoPMO.Utils
  alias RintoPMOWeb.Plugs.ActorToken

  # Read and append only. A conversation is a record of what happened, so there
  # is no update and no delete for a message.
  def index(conn, %{"conversation_id" => conversation_id} = params) do
    context = conversations_context()
    conversation = context.get_conversation!(conversation_id)

    with {:ok, opts} <- message_opts(params) do
      messages = context.list_messages(conversation, opts)
      render(conn, :index, messages: messages)
    end
  end

  def show(conn, %{"conversation_id" => conversation_id, "id" => id}) do
    context = conversations_context()
    conversation = context.get_conversation!(conversation_id)
    message = context.get_message!(conversation, id)
    render(conn, :show, message: message)
  end

  def create(conn, %{"conversation_id" => conversation_id} = params) do
    context = conversations_context()
    conversation = context.get_conversation!(conversation_id)

    attrs =
      params
      |> Map.delete("conversation_id")
      |> attribute(conn)

    with {:ok, message} <- context.append_message(conversation, attrs) do
      conn
      |> put_status(:created)
      |> render(:show, message: message)
    end
  end

  # A person's turn is theirs, and the token already says which person -- the
  # same rule `RintoPMOWeb.ConversationChannel` follows on the live path, which
  # is where a person's turn normally arrives.
  #
  # An assistant turn is left alone. Its author is not this endpoint's to know:
  # whatever ran the model is the only thing that can say which actor spoke and
  # under which provider and model, and it says so in the body. Forcing the
  # caller in would credit a person with a model's turn.
  defp attribute(%{"role" => "user"} = attrs, conn) do
    Map.put(attrs, "actor_id", ActorToken.current_actor!(conn).id)
  end

  defp attribute(attrs, _conn), do: attrs

  defp message_opts(params) do
    with {:ok, opts} <- after_position(params) do
      limit(params, opts)
    end
  end

  defp after_position(params) do
    case Map.get(params, "after_position") do
      nil ->
        {:ok, %{}}

      value ->
        case Integer.parse(to_string(value)) do
          {position, ""} when position >= 0 -> {:ok, %{after_position: position}}
          _invalid -> {:error, :bad_request, %{"after_position" => ["is invalid"]}}
        end
    end
  end

  defp limit(params, opts) do
    case Map.get(params, "limit") do
      nil ->
        {:ok, opts}

      value ->
        case Integer.parse(to_string(value)) do
          {limit, ""} when limit in 1..200 -> {:ok, Map.put(opts, :limit, limit)}
          _invalid -> {:error, :bad_request, %{"limit" => ["must be between 1 and 200"]}}
        end
    end
  end

  defp conversations_context, do: Utils.module(:conversations)
end
