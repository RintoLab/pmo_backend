defmodule RintoPMOWeb.Router do
  use RintoPMOWeb, :router

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/api/v1", RintoPMOWeb.V1 do
    pipe_through :api

    resources "/actors", ActorController, only: [:index, :show, :create, :update]
  end
end
