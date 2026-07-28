defmodule RintoPMOWeb.Router do
  use RintoPMOWeb, :router

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/api", RintoPMOWeb do
    pipe_through :api
  end
end
