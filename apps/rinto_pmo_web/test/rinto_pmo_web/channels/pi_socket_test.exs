defmodule RintoPMOWeb.PiSocketTest do
  use RintoPMOWeb.ChannelCase, async: true

  alias RintoPMO.Actors
  alias RintoPMOWeb.PiSocket

  test "connects a client carrying the configured token", %{current_actor: actor} do
    assert {:ok, socket} = connect(PiSocket, %{"token" => Actors.configured_token()})
    assert socket.assigns.current_actor.id == actor.id
  end

  test "refuses a connection carrying no token" do
    assert :error = connect(PiSocket, %{})
  end

  test "refuses a connection carrying the wrong token" do
    assert :error = connect(PiSocket, %{"token" => "not-the-configured-token"})
  end

  # Nothing hangs a connection up today, but the topic is what would: a
  # connection has to be findable by the person on the other end of it.
  test "names the connection after its actor", %{current_actor: actor} do
    {:ok, socket} = connect(PiSocket, %{"token" => Actors.configured_token()})

    assert PiSocket.id(socket) == "actor_socket:#{actor.id}"
  end
end
