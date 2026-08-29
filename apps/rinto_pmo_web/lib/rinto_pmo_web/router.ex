defmodule RintoPMOWeb.Router do
  use RintoPMOWeb, :router

  pipeline :api do
    plug :accepts, ["json"]
    # No route is exempt. There is nothing to bootstrap over HTTP and nothing
    # to recover: the token is agreed in advance and configured on both sides,
    # so a client that cannot authenticate is a client with the wrong config
    # file, which is not something this API can fix for it.
    plug RintoPMOWeb.Plugs.ActorToken
  end

  scope "/api/v1", RintoPMOWeb.V1 do
    pipe_through :api

    # Who the token says you are. This is the whole of "log in": there is no
    # session to establish, so a client resolves its identity once and keeps it.
    # Nothing here can change the token -- it is configuration on both sides,
    # and rotating it means editing those files and restarting.
    get "/actors/me", ActorController, :me

    resources "/actors", ActorController, only: [:index, :show, :create, :update]

    # Which actor does a job that belongs to no single topic -- naming them, so
    # far. A runtime choice rather than configuration: it is picked while
    # looking at the actor list, and changed after seeing a few of the results.
    get "/settings", SettingController, :index
    put "/settings/:key", SettingController, :update
    # What each week holds and what did not fit. Not nested under a project:
    # a week's minutes are shared across every project, so packing one project
    # alone would hand it the whole week. A per-project view filters this.
    get "/schedule", ScheduleController, :index

    # The same subject read backwards: not a forecast but what the clocks
    # recorded. A separate endpoint rather than a flag, because a client that
    # could ask for both at once would get one shape carrying two kinds of
    # claim. This one *can* be scoped to a project -- the refusal above is
    # about arithmetic, and nothing about the past is computed that way.
    get "/history", ScheduleController, :history

    # The same record read as arithmetic: what the estimates turned out to be
    # worth, by week and by story point. It is the only loop that lets the
    # estimator be checked against anything, and it was missing for as long as
    # the numbers have been collected.
    get "/calibration", CalibrationController, :index

    # Every dependency edge at once. `/tasks/:id/dependencies` answers about
    # one task, which is a request per bar for anything drawing arrows; this
    # is the same facts in one call, as bare pairs of ids.
    get "/dependencies", TaskController, :edges

    # Which days are not what the weekend rule says. Statutory holidays and the
    # weekends worked to make up for them are fetched daily and are read-only
    # here; leave is the half a person writes, and is the reason this table
    # would be worth having even if the importer never ran.
    get "/calendar/days", CalendarController, :index
    put "/calendar/days/:day/leave", CalendarController, :put_leave
    delete "/calendar/days/:day/leave", CalendarController, :delete_leave

    get "/ai_models", AIModelController, :index
    post "/ai_models/refresh", AIModelController, :refresh

    resources "/projects", ProjectController,
      only: [:index, :show, :create, :update, :delete],
      param: "slug" do
      resources "/repos", ProjectRepoController, only: [:index, :show, :create, :update, :delete]

      # Where a branch of this repository is on this machine, cloned or fetched
      # first if it is not there or has gone stale. The only door to the
      # workspace: nothing else tells a caller a path.
      post "/repos/:id/checkout", ProjectRepoController, :checkout

      # The same work, asked for by a person: queued, answered with the job.
      # See the controller for why the two are not one endpoint.
      post "/repos/:id/sync", ProjectRepoController, :sync

      # The backlog is a property of a project, so filing and browsing happen
      # here. Everything done *to* one task lives at `/tasks/:id` -- an agent
      # that pulled a task out of the pool holds its id and not the slug it
      # came from.
      get "/tasks/stats", TaskController, :stats
      resources "/tasks", TaskController, only: [:index, :create]
    end

    # How a Markdown body would be cut into blocks, without creating anything.
    # The split happens here, so this is where an author checks it.
    post "/documents/preview_blocks", DocumentController, :preview_blocks

    # What the `rinto://` links in a body point at: titles to preview, and
    # whether the target is still there. A POST for the same reason
    # `preview_blocks` is one -- a read whose input does not fit in a URL.
    post "/references/resolve", ReferenceController, :resolve

    # The other direction: everything whose text points at one thing. Keyed by
    # the canonical URI, so what a body cites and what is asked here are the
    # same string. There is deliberately no outbound counterpart -- a client
    # holds the body and can read its own references off it.
    get "/backlinks", BacklinkController, :index

    # Finding things by meaning: an embedded query against embedded content,
    # then a reranker. One kind of thing per request -- see `RintoPMO.Search`
    # on why nothing merges a ranking across types.
    get "/search", SearchController, :index

    # Adopting a scratch document as a formal one. A person's action, so it has
    # no counterpart in the agent CLI.
    post "/documents/:id/formalize", DocumentController, :formalize

    # Turning a plan into the work it implies. Answers with the attempt rather
    # than the breakdown -- the model call runs in a job, and what a client
    # does next is watch `document:{id}` on the socket. The `GET` is for one
    # that would rather ask than listen.
    post "/documents/:id/decompose", DocumentController, :decompose
    get "/documents/:id/decomposition", DocumentController, :decomposition

    # And the other end of it: the breakdown somebody adopted becomes the work.
    # An action on the document because that is what it consumes -- the
    # document comes out `applied` and cannot be filed a second time.
    post "/documents/:id/file_breakdown", DocumentController, :file_breakdown

    resources "/documents", DocumentController, only: [:index, :show, :create, :delete] do
      resources "/revisions", DocumentRevisionController,
        only: [:index, :show, :create],
        param: "revision_id"

      # An agent writes through proposals, never straight to a revision: a
      # revision is what a person agreed to.
      resources "/proposals", BlockProposalController, only: [:index, :show, :create]

      post "/proposals/:id/decide", BlockProposalController, :decide

      # Carrying a whole-document proposal across what landed under it, rather
      # than throwing it away and asking the model again.
      post "/proposals/:id/rebase", BlockProposalController, :rebase
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

      # An annotation is over when a person says it is, and that is the only
      # thing this mark means. Deliberately not part of the update payload:
      # editing the wording must never be able to close the thread.
      #
      # A pair rather than three verbs. "Settled by this revision" and "settled
      # without one" are the same decision carrying a different pointer, so
      # `confirm` takes an optional `confirmed_by_revision_id` and there is no
      # second name for the case where it is absent. `DELETE` is the way back,
      # the way it is for a day's leave.
      post "/annotations/:id/confirm", AnnotationController, :confirm
      delete "/annotations/:id/confirm", AnnotationController, :unconfirm

      # The only thing that writes here that is not a person. One click, one
      # reply: nothing works out on its own whether a discussion has concluded,
      # because the asking is the boundary. Answers with the job -- watch
      # `document:{id}` for the end of it.
      post "/annotations/:id/reply", AnnotationController, :reply

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

    # What a write has to look like: the shapes `create`, `update` and `split`
    # read. It belongs to no project and no task, and it sits ahead of
    # `resources` so that `schema` is not read as an id.
    get "/tasks/schema", TaskController, :schema

    # The pool, across every project. Capacity is one person's and spans all of
    # them -- `/schedule` says so by refusing to filter by project -- so "what
    # is there to pick up" is not a per-project question, and answering it by
    # walking the projects would leave the client to invent the merge order.
    get "/tasks", TaskController, :index

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

    # "This cannot start until that is done." Not a field on the task, because
    # an edge belongs to neither end of itself; and not a `rinto://` reference
    # in a body, because `links` rows are derivable from the text they were
    # read out of and this one is a fact somebody asserted.
    get "/tasks/:id/dependencies", TaskController, :dependencies
    post "/tasks/:id/dependencies", TaskController, :add_dependency
    delete "/tasks/:id/dependencies/:depends_on_id", TaskController, :remove_dependency

    # One endpoint per event rather than a settable `status`: the machine is
    # the API, so a client cannot invent a transition the domain refuses.
    post "/tasks/:id/start", TaskController, :start
    post "/tasks/:id/complete", TaskController, :complete
    post "/tasks/:id/cancel", TaskController, :cancel
    post "/tasks/:id/reopen", TaskController, :reopen

    # Direct model calls, one-shot rather than a conversation. A work item is
    # estimated itself; a summary is estimated as the work under it that still
    # has no value. Results write onto the task fields; a person who disagrees
    # PATCHes, and asking twice is allowed -- this is a helper for an empty
    # field, not an authority on what belongs in it.
    #
    # One endpoint taking `kind`, unlike the transitions above. Those are
    # events, and one route each is what stops a client inventing a transition
    # the domain refuses. Difficulty and time are not two events: they are one
    # operation putting a different question to the model.
    #
    # Answers with the *job*. Nothing records the asking: what a client does
    # next is listen on `task:{id}`, and `GET /jobs/{job_id}` is the way back
    # if it was not listening when the answer came.
    post "/tasks/:id/estimate", TaskController, :estimate

    # The only thing a client can ask about a background job, and the only
    # place anything about one is kept. `404` means pruned, which means over --
    # see `RintoPMO.Jobs`.
    get "/jobs/:id", JobController, :show

    resources "/attachments", AttachmentController, only: [:show, :create, :delete]
    get "/attachments/:id/content", AttachmentController, :content

    resources "/repo_credentials", RepoCredentialController,
      only: [:index, :show, :create, :update, :delete]
  end
end
