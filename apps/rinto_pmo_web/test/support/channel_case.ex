defmodule RintoPMOWeb.ChannelCase do
  @moduledoc """
  Test case for channels.

  Sets up `Phoenix.ChannelTest` against `RintoPMOWeb.Endpoint` and, for tests
  that touch the database, the SQL sandbox.
  """

  use ExUnit.CaseTemplate

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

  setup tags do
    RintoPMO.DataCase.setup_sandbox(tags)
    :ok
  end
end
