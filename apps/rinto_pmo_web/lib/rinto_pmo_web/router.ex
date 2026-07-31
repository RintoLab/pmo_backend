defmodule RintoPMOWeb.Router do
  use RintoPMOWeb, :router

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/api/v1", RintoPMOWeb.V1 do
    pipe_through :api

    resources "/actors", ActorController, only: [:index, :show, :create, :update]

    resources "/projects", ProjectController,
      only: [:index, :show, :create, :update, :delete],
      param: "slug" do
      resources "/repos", ProjectRepoController, only: [:index, :show, :create, :update, :delete]
    end

    resources "/documents", DocumentController, only: [:index, :show, :create, :delete] do
      resources "/revisions", DocumentRevisionController,
        only: [:index, :show, :create],
        param: "revision_id"
    end

    resources "/repo_credentials", RepoCredentialController,
      only: [:index, :show, :create, :update, :delete]
  end
end
