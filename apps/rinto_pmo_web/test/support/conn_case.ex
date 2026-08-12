defmodule RintoPMOWeb.ConnCase do
  @moduledoc """
  This module defines the test case to be used by
  tests that require setting up a connection.

  Such tests rely on `Phoenix.ConnTest` and also
  import other functionality to make it easier
  to build common data structures and query the data layer.

  Finally, if the test case interacts with the database,
  we enable the SQL sandbox, so changes done to the database
  are reverted at the end of every test. If you are using
  PostgreSQL, you can even run database tests asynchronously
  by setting `use RintoPMOWeb.ConnCase, async: true`, although
  this option is not recommended for other databases.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      # The default endpoint for testing
      @endpoint RintoPMOWeb.Endpoint

      use RintoPMOWeb, :verified_routes

      # Import conveniences for testing with connections
      import Plug.Conn
      import Phoenix.ConnTest
      import Hammox
      import RintoPMO.Factory
      import RintoPMOWeb.ConnCase

      setup :verify_on_exit!
    end
  end

  @doc """
  Puts `actor`'s token on a connection.
  """
  def authenticate(conn, actor) do
    Plug.Conn.put_req_header(conn, "authorization", "Bearer #{actor.token}")
  end

  # Every route is behind `RintoPMOWeb.Plugs.ActorToken`, so an unauthenticated
  # `conn` would test the plug and nothing else. Tests get one that is already
  # somebody, and the ones that are about being refused build their own.
  #
  # The actor is real rather than mocked: the plug reads `RintoPMO.Actors`
  # directly, on purpose. See the plug's moduledoc.
  setup tags do
    RintoPMO.DataCase.setup_sandbox(tags)

    actor =
      RintoPMO.Factory.insert(:actor,
        kind: :human,
        token: RintoPMO.Actors.generate_token()
      )

    {:ok, conn: authenticate(Phoenix.ConnTest.build_conn(), actor), current_actor: actor}
  end
end
