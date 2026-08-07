defmodule RintoPMOWeb.Router do
  use RintoPMOWeb, :router

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/api/v1", RintoPMOWeb.V1 do
    pipe_through :api

    resources "/actors", ActorController, only: [:index, :show, :create, :update]
    get "/ai_models", AIModelController, :index
    post "/ai_models/refresh", AIModelController, :refresh

    resources "/projects", ProjectController,
      only: [:index, :show, :create, :update, :delete],
      param: "slug" do
      resources "/repos", ProjectRepoController, only: [:index, :show, :create, :update, :delete]
    end

    resources "/documents", DocumentController, only: [:index, :show, :create, :delete] do
      resources "/revisions", DocumentRevisionController,
        only: [:index, :show, :create],
        param: "revision_id"

      # An agent writes through proposals, never straight to a revision: a
      # revision is what a person agreed to.
      resources "/proposals", BlockProposalController, only: [:index, :show, :create]

      post "/proposals/:id/decide", BlockProposalController, :decide
      get "/contentions", BlockProposalController, :contentions

      # The document as one topic sees it: its own proposals standing in, and
      # only the count of anyone else's.
      get "/conversations/:conversation_id/blocks", BlockProposalController, :blocks

      # Where a revision, the annotations it settles, and the proposals it
      # accepts all move together.
      post "/commit", DocumentRevisionController, :commit

      resources "/annotations", AnnotationController,
        only: [:index, :show, :create, :update, :delete] do
        resources "/replies", AnnotationReplyController,
          only: [:create, :update, :delete],
          param: "reply_id"
      end

      # Status is deliberately not part of the annotation update payload: only
      # a human decision moves it, never an edit of the wording.
      post "/annotations/:id/resolve", AnnotationController, :resolve
      post "/annotations/:id/dismiss", AnnotationController, :dismiss
      post "/annotations/:id/reopen", AnnotationController, :reopen

      # The many-to-many between annotations and topics, derived from message
      # refs. No join table backs this.
      get "/annotations/:id/conversations", AnnotationController, :conversations
    end

    # Not nested under documents: a topic can span several documents, or none,
    # so it belongs to no document's URL space.
    resources "/conversations", ConversationController, only: [:index, :show, :create, :update] do
      # Append and read only -- a conversation records what happened.
      resources "/messages", MessageController, only: [:index, :show, :create]
    end

    # Heating and cooling. Neither creates nor destroys a topic -- they only
    # decide whether it currently costs a pi process.
    post "/conversations/:id/open", ConversationController, :open
    post "/conversations/:id/close", ConversationController, :close

    resources "/attachments", AttachmentController, only: [:show, :create, :delete]
    get "/attachments/:id/content", AttachmentController, :content

    resources "/repo_credentials", RepoCredentialController,
      only: [:index, :show, :create, :update, :delete]
  end
end
