defmodule RintoPMOWeb.PiSocket do
  @moduledoc """
  WebSocket carrying `RintoPMOWeb.PiSessionChannel`.

  ## Authentication

  There is none, matching the rest of this application: the REST API under
  `/api/v1` is equally open and `RintoPMO.Actors.Actor` deliberately carries no
  authentication fields. `connect/3` is where that changes -- return
  `{:ok, assign(socket, :actor_id, id)}` for an authenticated connection and
  `:error` to refuse one, then have the channel authorise per session.

  Weigh that sooner rather than later for this socket in particular: it drives
  an AI agent and answers its confirmation prompts, which is a good deal more
  than the read-mostly REST surface exposes.
  """

  use Phoenix.Socket

  channel "pi_session:*", RintoPMOWeb.PiSessionChannel

  @impl true
  def connect(_params, socket, _connect_info), do: {:ok, socket}

  # Anonymous sockets cannot be targeted by `Endpoint.broadcast/3`. Sessions are
  # addressed by topic, so nothing needs to.
  @impl true
  def id(_socket), do: nil
end
