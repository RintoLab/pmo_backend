defmodule RintoPMOWeb.PiSocket do
  @moduledoc """
  WebSocket carrying `RintoPMOWeb.ConversationChannel`.

  ## Authentication

  The same actor token the REST API takes, passed as a connect parameter
  because a browser's WebSocket cannot set headers:

      new Socket("/socket", {params: {token: "<token>"}})

  A connection without a valid one is refused outright. This socket earns that
  more than the REST surface does: it drives an AI agent and answers its
  confirmation prompts, so it can spend money and act on a repository, which no
  `GET` can.

  The actor is resolved once, at connect, and every channel on the connection
  reads it from `socket.assigns.current_actor`. A prompt is recorded as that
  person's turn -- the client never says whose turn it is.

  ## Rotating a token hangs up

  `id/1` names the connection after its actor, so
  `Endpoint.broadcast("actor_socket:<id>", "disconnect", %{})` drops every live
  connection that actor holds. `RintoPMOWeb.V1.ActorController.rotate_token/2`
  does exactly that: a token that has been replaced must not keep working
  because it happens to already be attached to an open socket.
  """

  use Phoenix.Socket

  alias RintoPMO.Actors

  channel "conversation:*", RintoPMOWeb.ConversationChannel

  @impl true
  def connect(params, socket, _connect_info) do
    case Actors.authenticate(params["token"]) do
      {:ok, actor} -> {:ok, assign(socket, :current_actor, actor)}
      # The handshake has no body to carry a reason in, so the two refusals the
      # REST side distinguishes collapse into one here.
      {:error, _unauthorized_or_unconfigured} -> :error
    end
  end

  @impl true
  def id(socket), do: "actor_socket:#{socket.assigns.current_actor.id}"

  @doc """
  The topic `id/1` puts a connection on, for hanging up on one actor.
  """
  @spec socket_id(UUIDv7.t()) :: String.t()
  def socket_id(actor_id), do: "actor_socket:#{actor_id}"
end
