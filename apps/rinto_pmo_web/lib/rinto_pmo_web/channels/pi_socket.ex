defmodule RintoPMOWeb.PiSocket do
  @moduledoc """
  WebSocket carrying `RintoPMOWeb.ConversationChannel` and
  `RintoPMOWeb.DocumentChannel`.

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

  `id/1` names the connection after its actor, so
  `Endpoint.broadcast("actor_socket:<id>", "disconnect", %{})` would drop every
  live connection that actor holds. Nothing does that today: the token is
  configuration, and changing it means restarting the server that holds these
  connections open.
  """

  use Phoenix.Socket

  alias RintoPMO.Actors

  channel "conversation:*", RintoPMOWeb.ConversationChannel
  channel "document:*", RintoPMOWeb.DocumentChannel

  @impl true
  def connect(params, socket, _connect_info) do
    case Actors.authenticate(params["token"]) do
      {:ok, actor} -> {:ok, assign(socket, :current_actor, actor)}
      # The handshake has no body to carry a reason in, so the refusals the
      # REST side distinguishes collapse into one here.
      {:error, _unauthorized_or_unconfigured} -> :error
    end
  end

  @impl true
  def id(socket), do: "actor_socket:#{socket.assigns.current_actor.id}"
end
