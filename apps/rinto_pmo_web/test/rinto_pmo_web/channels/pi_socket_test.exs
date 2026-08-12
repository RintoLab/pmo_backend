defmodule RintoPMOWeb.PiSocketTest do
  use RintoPMOWeb.ChannelCase, async: true

  alias RintoPMO.Actors
  alias RintoPMOWeb.PiSocket

  test "connects an actor holding a valid token", %{current_actor: actor} do
    assert {:ok, socket} = connect(PiSocket, %{"token" => actor.token})
    assert socket.assigns.current_actor.id == actor.id
  end

  test "refuses a connection carrying no token" do
    assert :error = connect(PiSocket, %{})
  end

  test "refuses a connection carrying the wrong token" do
    assert :error = connect(PiSocket, %{"token" => Actors.generate_token()})
  end

  # Rotating has to reach connections that are already open, or a replaced
  # token goes on working for as long as a tab stays on the page.
  test "names the connection after its actor, so it can be hung up on", %{current_actor: actor} do
    {:ok, socket} = connect(PiSocket, %{"token" => actor.token})

    assert PiSocket.id(socket) == PiSocket.socket_id(actor.id)
  end
end
