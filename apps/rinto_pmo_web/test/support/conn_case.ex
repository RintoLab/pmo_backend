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
  Puts the configured token on a connection.

  There is only one, and it belongs to nobody in particular: it says a request
  may be answered, and who that makes the caller is
  `RintoPMO.Actors.get_owner/0`'s answer rather than anything the header
  carries.
  """
  def authenticate(conn) do
    Plug.Conn.put_req_header(
      conn,
      "authorization",
      "Bearer #{RintoPMO.Actors.configured_token()}"
    )
  end

  # Every route is behind `RintoPMOWeb.Plugs.ActorToken`, so an unauthenticated
  # `conn` would test the plug and nothing else. Tests get one that is already
  # somebody, and the ones that are about being refused build their own.
  #
  # The human is real rather than mocked: the plug reads `RintoPMO.Actors`
  # directly, on purpose. See the plug's moduledoc. It is inserted first so
  # that it is the earliest human, and so the one every request is answered as
  # however many actors a test goes on to create.
  setup tags do
    RintoPMO.DataCase.setup_sandbox(tags)

    actor = RintoPMO.Factory.insert(:actor, kind: :human)

    {:ok, conn: authenticate(Phoenix.ConnTest.build_conn()), current_actor: actor}
  end
end
