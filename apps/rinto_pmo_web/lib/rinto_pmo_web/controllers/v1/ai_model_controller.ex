defmodule RintoPMOWeb.V1.AIModelController do
  use RintoPMOWeb, :controller

  alias RintoPMO.Agent.ModelCatalog

  def index(conn, _params) do
    render(conn, :index,
      providers: ModelCatalog.list_providers(),
      status: ModelCatalog.status()
    )
  end

  # Only a signal: discovery takes about a second, so waiting for it would tie
  # up the request for no benefit. Clients poll `index` and watch `status` --
  # which is also where a failed discovery surfaces, hence no error response
  # here.
  def refresh(conn, _params) do
    :ok = ModelCatalog.refresh()

    send_resp(conn, :no_content, "")
  end
end
