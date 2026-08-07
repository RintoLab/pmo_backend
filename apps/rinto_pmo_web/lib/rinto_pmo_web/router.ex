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

      # The backlog is a property of a project, so filing and browsing happen
      # here. Everything done *to* one task lives at `/tasks/:id` -- an agent
      # that pulled a task out of the pool holds its id and not the slug it
      # came from.
      get "/tasks/stats", TaskController, :stats
      resources "/tasks", TaskController, only: [:index, :create]
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

    # Cooling is not deleting: the process goes, every message stays. There is
    # no matching "open" -- you cannot talk to a cold topic, so sending a
    # message is what heats one.
    post "/conversations/:id/close", ConversationController, :close

    # Delete is not the opposite of create here -- `cancel` is what records
    # that work was dropped. This is for rows that should never have existed,
    # such as a breakdown an agent got wrong. Emptying a cover of its last
    # child turns the cover back into a job.
    resources "/tasks", TaskController, only: [:show, :update, :delete]

    # Distribution: a PM pushes with `assign`, an actor pulls with `claim`.
    # Both write the same assignee, so nothing downstream has to know which
    # happened. `release` is the way back to the pool, and is not a cancel --
    # the work still needs doing.
    post "/tasks/:id/assign", TaskController, :assign
    post "/tasks/:id/claim", TaskController, :claim
    post "/tasks/:id/release", TaskController, :release

    # The one thing that moves `kind`, and an operation rather than a field:
    # promoting a job to a cover drops its assignee and its clocks, which must
    # not be able to ride along with an edit of the title.
    post "/tasks/:id/split", TaskController, :split

    # One endpoint per event rather than a settable `status`: the machine is
    # the API, so a client cannot invent a transition the domain refuses.
    post "/tasks/:id/start", TaskController, :start
    post "/tasks/:id/complete", TaskController, :complete
    post "/tasks/:id/cancel", TaskController, :cancel
    post "/tasks/:id/reopen", TaskController, :reopen

    resources "/attachments", AttachmentController, only: [:show, :create, :delete]
    get "/attachments/:id/content", AttachmentController, :content

    resources "/repo_credentials", RepoCredentialController,
      only: [:index, :show, :create, :update, :delete]
  end
end
