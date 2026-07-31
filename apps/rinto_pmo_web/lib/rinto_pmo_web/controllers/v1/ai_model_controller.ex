defmodule RintoPMOWeb.V1.AIModelController do
  use RintoPMOWeb, :controller

  alias RintoPMO.Agent.ModelCatalog

  def index(conn, _params) do
    providers = ModelCatalog.list_providers()

    render(conn, :index, providers: providers)
  end
end
