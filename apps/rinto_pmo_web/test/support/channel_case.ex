defmodule RintoPMOWeb.ChannelCase do
  @moduledoc """
  Test case for channels.

  Sets up `Phoenix.ChannelTest` against `RintoPMOWeb.Endpoint` and, for tests
  that touch the database, the SQL sandbox.
  """

  use ExUnit.CaseTemplate

  # Also here, not only in `using/0`: `connect_as/1` below is compiled in this
  # module, and the `connect` macro reads `@endpoint` from wherever it expands.
  @endpoint RintoPMOWeb.Endpoint

  import Phoenix.ChannelTest, only: [connect: 2]

  using do
    quote do
      # The default endpoint for testing
      @endpoint RintoPMOWeb.Endpoint

      import Hammox
      import Phoenix.ChannelTest
      import RintoPMO.Factory
      import RintoPMOWeb.ChannelCase

      setup :verify_on_exit!
    end
  end

  @doc """
  A connected socket carrying `actor`'s token, as a real client would have.
  """
  def connect_as(actor) do
    {:ok, socket} = connect(RintoPMOWeb.PiSocket, %{"token" => actor.token})

    socket
  end

  @doc """
  Another connection for the actor this case set up.

  A fresh one each call, because two tabs are two connections and a socket
  cannot join the same topic twice. The actor is read back from the test
  process rather than the ExUnit context so that plain helpers -- which never
  see the context -- can open a connection too.
  """
  def connect_as, do: connect_as(current_actor())

  @doc """
  The actor this case set up.
  """
  def current_actor, do: Process.get(__MODULE__) || raise("the case set up no actor")

  # Every connection is behind a token, so a case that set none up could only
  # test being refused. The ones that do test that build their own actor.
  setup tags do
    RintoPMO.DataCase.setup_sandbox(tags)

    actor =
      RintoPMO.Factory.insert(:actor,
        kind: :human,
        token: RintoPMO.Actors.generate_token()
      )

    Process.put(__MODULE__, actor)

    {:ok, current_actor: actor, socket: connect_as(actor)}
  end
end
