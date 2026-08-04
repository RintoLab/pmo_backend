defmodule RintoPMOWeb.V1.MessageController do
  use RintoPMOWeb, :controller

  alias RintoPMO.Utils

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
    attrs = Map.delete(params, "conversation_id")

    with {:ok, message} <- context.append_message(conversation, attrs) do
      conn
      |> put_status(:created)
      |> render(:show, message: message)
    end
  end

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
