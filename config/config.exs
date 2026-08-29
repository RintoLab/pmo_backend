# This file is responsible for configuring your umbrella
# and **all applications** and their dependencies with the
# help of the Config module.
#
# Note that all applications in your umbrella share the
# same configuration and dependencies, which is why they
# all use the same configuration file. If you want different
# configurations or dependencies per app, it is best to
# move said applications out of the umbrella.
import Config

# Configure Mix tasks and generators
config :rinto_pmo,
  namespace: RintoPMO,
  ecto_repos: [RintoPMO.Repo],
  pi_executable: "pi",
  injectors: [
    actors: RintoPMO.Actors,
    annotations: RintoPMO.Annotations,
    attachments: RintoPMO.Attachments,
    conversations: RintoPMO.Conversations,
    documents: RintoPMO.Documents,
    projects: RintoPMO.Projects,
    repo_credentials: RintoPMO.RepoCredentials,
    tasks: RintoPMO.Tasks,
    # Each layer of pi model discovery, so a test of one mocks the next.
    rpc: RintoPMO.Agent.Rpc,
    os_process: RintoPMO.OSProcess,
    # The model calls made outside a conversation, each swappable on its own so
    # that everything around them -- eligibility, fallbacks, conditional writes
    # -- is testable without a model.
    title_generator: RintoPMO.Agent.TitleGenerator,
    wbs_generator: RintoPMO.Agent.WbsGenerator,
    task_estimator: RintoPMO.Agent.TaskEstimator,
    annotation_responder: RintoPMO.Agent.AnnotationResponder,
    # Reading what a `rinto://` reference points at. Only the read side is
    # injected: parsing a reference is pure and belongs to every write path,
    # and mocking it would let a document test lie about what it stored.
    reference_resolver: RintoPMO.References.Resolver,
    # Only the read side of the reference index. `sync/5` and `purge/3` stay out
    # of the injector on purpose: they are part of writing correctly, and a mock
    # in their place would let a document test pass over an index nothing wrote.
    links: RintoPMO.Links,
    # Embeddings and reranking. A service, not an actor -- see `RintoPMO.AI`.
    ai: RintoPMO.AI,
    search: RintoPMO.Search,
    # Fetched rather than vendored: a checked-in holiday file goes stale in
    # silence, and a stale calendar reports the October holiday as seven
    # working days with nothing anywhere complaining.
    holidays: RintoPMO.Calendar.Holidays
  ]

# The local inference service: embeddings and reranking.
#
# Not pi. pi is a coding assistant that holds a conversation, and neither of
# these is a conversation -- they are single-shot calls whose whole job is to
# turn text into numbers. They also have no actor behind them: `title_actor`
# and the rest name *who* is answering, and nobody is answering here. So this
# is configured as a service address rather than through `RintoPMO.Settings`.
#
# `token` is deliberately absent from this file. It is a credential, and
# credentials are read at runtime -- see `config/runtime.exs`, and
# `config/dev.secret.exs` for a developer's own copy.
config :rinto_pmo, :ai,
  base_url: "https://ai.kenton.wang/v1",
  embedding_uri: "/embeddings",
  rerank_uri: "/rerank",
  score_uri: "/score",
  # `"qwen3"` is the name this deployment serves under, not the model. Two
  # different models answer to it, one per endpoint:
  #
  #   * `/embeddings` -- Qwen3-Embedding-0.6B, whose 1024 dimensions are what
  #     every `embedding` column is declared as. Changing it means rewriting
  #     those columns, so it is not a setting to flip casually.
  #   * `/rerank` -- Qwen3-Reranker-0.6B, a separate model in that family
  #     rather than the embedding model scoring pairs.
  #
  # Three keys rather than one because they are free to diverge, and one day
  # will: the two sit at 0.6B, and 4B is materially better on Chinese content
  # (C-MTEB retrieval 71.0 -> 77.0, reranking 71.3 -> 75.9). Do not read the
  # shared name as a shared model -- `GET /v1/models` reports one entry, which
  # is the gateway answering for whichever instance it routed to.
  embedding_model: "qwen3",
  rerank_model: "qwen3",
  score_model: "qwen3",
  # On the query side only -- Qwen3-Embedding is trained with an instruction
  # there and none on the document side. Wording is a tuning knob, not a
  # contract, which is why it is here rather than in the code. Qwen measure a
  # 1-5% retrieval drop from leaving it out, and advise writing it in English
  # even for other-language content, which is why this English sentence sits in
  # front of Chinese queries.
  #
  # The reranker takes an instruction of its own and is currently given none,
  # so it falls back to its default -- a *web search* task description, which
  # is not what this is. Worth fixing when the reranker is worth tuning: at
  # 0.6B it scores 5.41 on FollowIR, so it barely follows one.
  query_instruction:
    "Given a search query, retrieve relevant passages from a project's documents, tasks and discussions",
  # Wall clock for one call. These are single-shot transformations, not a model
  # thinking, so a slow one is a service in trouble rather than one working.
  timeout: 30_000,
  token: nil

# `vector` is not a type Postgrex knows natively -- it comes with the pgvector
# extension -- so the repo is given a type module that includes it. Set here
# rather than per environment: it is a property of the schema, not of a
# deployment.
config :rinto_pmo, RintoPMO.Repo, types: RintoPMO.PostgrexTypes

config :rinto_pmo, RintoPMO.Links,
  # Characters of a source's body carried in a backlink row. Shorter than a
  # hover card's: a backlink panel is a list of many, and a preview long enough
  # to read in isolation makes the list unscannable.
  max_excerpt_chars: 120

config :rinto_pmo, RintoPMO.References.Resolver,
  # References resolved in one request. A body carries as many as its author
  # wrote, so the ceiling is on the request rather than on the document -- a
  # client rendering a long page is expected to ask in batches.
  max_references: 200,
  # Characters of a target's body carried back for a preview. Enough to tell
  # two similar things apart in a hover card, never enough to be a substitute
  # for opening the thing.
  max_excerpt_chars: 200

config :rinto_pmo, RintoPMO.Attachments,
  # Where uploaded image bytes live. Override per environment; a release should
  # point this at a volume that outlives the deploy.
  root: Path.expand("../apps/rinto_pmo/priv/attachments", __DIR__),
  # pi caps an inline image at 4.5MB before handing it to a provider
  # (`utils/image-resize-core.js`). Nothing resizes on the RPC path, so this is
  # the real ceiling rather than a hint.
  max_bytes: 4_500_000,
  # Well above pi's own 2000px auto-resize target, which exists to save tokens
  # rather than to satisfy an API. We cannot resize, so this only fences off the
  # sizes providers reject outright; clients should downscale for cost.
  max_dimension: 8_000

config :rinto_pmo, RintoPMO.Workspace,
  # Where the repositories registered against a project are kept on disk, so the
  # agent answering questions about a project can read its code. `nil` turns the
  # whole thing off: nothing is cloned and every call refuses. Set in
  # `config/runtime.exs` from RINTO_WORKSPACE_ROOT.
  #
  # Must not sit inside the release directory -- a deploy swaps that, and every
  # clone would be thrown away or orphaned with it.
  root: nil,
  # How long a mirror is trusted before the next checkout re-fetches. There is
  # no timer behind this: a project nobody is discussing is never fetched at
  # all. It exists because a repository may live on the public internet, where
  # even a fetch that finds nothing costs a round trip in front of a person.
  ttl_ms: :timer.minutes(5),
  # A fetch sits in front of somebody waiting for an answer, so it gives up
  # early and the stale snapshot is served with a note. A first clone has no
  # snapshot to fall back to and happens when a repository is registered rather
  # than in a conversation, so it may take as long as it takes.
  fetch_timeout: :timer.seconds(5),
  clone_timeout: :timer.minutes(2),
  # Everything that touches only the disk: rev-parse, worktree, reset. Slow only
  # if the machine is in trouble.
  local_timeout: :timer.seconds(15)

config :rinto_pmo, RintoPMO.Conversations,
  # Simultaneously running pi processes. Topics are unlimited; processes are
  # not, and nothing else in the system stops one from being started.
  max_active_sessions: 8,
  # Where the CLI an agent reaches for should call this API. Injected into the
  # agent's environment when set; left to whatever carries the CLI when not,
  # because the backend does not otherwise know its own public address and a
  # guessed one is worse than an absent one.
  agent_api_url: nil

config :rinto_pmo, RintoPMO.Conversations.Titles,
  # Automatic naming of topics from their first user message. Turning this off
  # leaves conversations unnamed rather than failing anything.
  enabled: true,
  # Characters of the first message sent to the naming model. A title is a
  # phrase; the rest of a long message says nothing more about the subject.
  max_message_chars: 2_000,
  # Characters per reference label. Enough to name the document, never enough
  # to be a briefing -- the naming call never sees a document's contents.
  max_summary_chars: 120

config :rinto_pmo, RintoPMO.Agent.TitleGenerator,
  # Which model names topics is *not* configured here: it is whichever actor
  # was put in the `title_actor` role, which is a runtime choice -- see
  # `RintoPMO.Settings` and `PUT /settings/title_actor`.
  #
  # Wall clock for the whole call. Nothing waits on it, but a naming job should
  # not hold a queue slot for a provider that has stopped answering.
  timeout: 20_000

config :rinto_pmo, RintoPMO.Agent.WbsGenerator,
  # Which model breaks documents down is *not* configured here either: it is
  # whichever actor holds the `decomposition_actor` role -- see
  # `RintoPMO.Settings` and `PUT /settings/decomposition_actor`.
  #
  # How long the call may produce **nothing** before it is treated as dead.
  # There is no budget for the call as a whole, deliberately: what decides how
  # long a breakdown takes is how much work the document implies, and cutting a
  # model off mid-answer throws away everything it has done. A model still
  # producing output is still working. See `RintoPMO.Agent.WbsGenerator`.
  #
  # The number has to clear the longest silence in a *healthy* call, which is
  # the wait before the first token. Three real design documents ran 98s to
  # 120s end to end when this was measured, so three minutes of complete
  # silence is well past anything a working call does.
  idle_timeout: 180_000

config :rinto_pmo, RintoPMO.Agent.TaskEstimator,
  # Which model rates difficulty and produces estimates is *not* configured
  # here: it is whichever actor holds the `estimation_actor` role -- see
  # `RintoPMO.Settings` and `PUT /settings/estimation_actor`.
  #
  # Silence, not duration, same as `WbsGenerator`: a model that is still
  # producing is still working. Three minutes of complete silence is well past
  # anything a working call does.
  idle_timeout: 180_000

config :rinto_pmo, RintoPMO.Agent.AnnotationResponder,
  # Same as the two above: the actor is the `annotation_actor` role, and the
  # timeout is on silence rather than on how long an answer takes.
  idle_timeout: 180_000

config :rinto_pmo, RintoPMO.Agent.PromptBuilder,
  # Characters of block content inlined per referenced document before the rest
  # is elided.
  max_document_chars: 20_000,
  # Documents listed in a project reference's index.
  max_project_documents: 50,
  # Turns handed back when a cold topic is revived. This is a safety valve, not
  # a budget: a hundred turns of chat is a few thousand tokens and the
  # documents they cite are deduplicated across them, which lands an order of
  # magnitude inside any current context window. It is set high enough that
  # reaching it should not happen, because the alternative to degrading here is
  # a request that overflows the window and fails outright -- a topic that
  # cannot be opened at all.
  max_conversation_turns: 200

config :rinto_pmo, RintoPMO.OSProcess,
  # Seconds between SIGTERM and SIGKILL when stopping a child.
  kill_timeout: 5,
  # Milliseconds to keep collecting output after a child exits.
  drain_timeout: 25,
  # Under `framing: :lines`, cap the pending partial line at this many bytes so
  # a child that never emits a newline cannot grow the buffer without bound.
  # Unbounded by default: cutting a line is lossy, so it is opt-in per child.
  max_line_bytes: :infinity

config :rinto_pmo, RintoPMO.Search,
  # Candidates pulled by cosine distance before reranking. Measured rather than
  # guessed: across three queries on this system's own content, the best result
  # after reranking sat at cosine rank 27, 25 and 56 -- so twenty would have
  # missed all three. Reranking a hundred costs about 100ms more than twenty,
  # so depth is nearly free and shallowness is not.
  #
  # The number also happens to be the one Qwen publishes its own reranker
  # figures on: every score in the Qwen3-Reranker table is measured over the
  # top-100 candidates retrieved by Qwen3-Embedding-0.6B, which is this exact
  # pairing. A local measurement and the model's published setup agreeing is
  # worth more than either alone, and it means the published numbers describe
  # a configuration we are actually running.
  #
  # Overridable per request -- see `RintoPMO.Search.search/2` on why the depth
  # is the number worth varying.
  recall_limit: 100,
  # The ceiling on a caller's own `recall_limit`. A safety valve rather than a
  # measurement: every candidate is one forward pass through the reranker and
  # one document in a single HTTP request, and a thousand blocks at a few
  # kilobytes apiece is already a multi-megabyte body. Refused rather than
  # clamped, so a caller comparing depths knows which depth it actually got.
  max_recall_limit: 1000,
  # Results handed back after reranking.
  result_limit: 20,
  # Characters of a hit's text carried back. Enough to see why it matched.
  max_excerpt_chars: 300

config :rinto_pmo, RintoPMO.Embeddings.Worker,
  # Rows embedded per source per pass. Also the signal for "there is more":
  # a full batch means come straight back rather than wait out the interval.
  batch_size: 100,
  # Seconds before the next pass when there was nothing much to do. The gap
  # between writing something and being able to find it, in other words --
  # short because it costs nothing, since a pass over an empty backlog is seven
  # indexed queries returning nothing.
  interval_seconds: 15

config :rinto_pmo, Oban,
  repo: RintoPMO.Repo,
  queues: [
    default: 10,
    # Width one: two passes at once would hand the same rows to the inference
    # service twice. `unique` on the worker keeps them from piling up as well.
    embeddings: 1
  ],
  plugins: [
    # Both workers that ask a model anything deduplicate over `:incomplete`,
    # which assumes a job cannot sit in `executing` forever. A node that dies
    # mid-call -- Ctrl-C on the dev server, a deploy -- leaves exactly that,
    # and the row then holds its uniqueness slot for good: that document can
    # never be decomposed again, that task can never be estimated again.
    # Lifeline is what makes the assumption true.
    #
    # `rescue_after` has to clear the longest *healthy* run, because Lifeline
    # cannot tell a dead node from a slow one and will rescue either. Neither
    # model call has a wall-clock budget -- they stop on silence, not on
    # duration (see `RintoPMO.Agent.WbsGenerator`) -- so there is no number to
    # derive this from. An hour is far past the two minutes real documents
    # take, and being late to rescue costs only waiting.
    {Oban.Plugins.Lifeline, rescue_after: :timer.minutes(60)},

    # `RintoPMO.Jobs` answers "no such job" as "it is over, stop waiting", and
    # that is only honest if the rows that disappear are the finished ones,
    # which is what pruning does. A day is long enough that a client polling a
    # job id always finds it, and short enough that the table does not grow
    # without bound.
    {Oban.Plugins.Pruner, max_age: 60 * 60 * 24},

    # The embedding pass keeps itself going by enqueueing the next one, which
    # works right up until a pass is discarded and the chain ends for good.
    # This does nothing while that chain is healthy -- the worker's `unique`
    # makes it a no-op -- and restarts it when it is not.
    {Oban.Plugins.Cron,
     crontab: [
       {"* * * * *", RintoPMO.Embeddings.Worker},
       # Daily, because the State Council amends its announcements: a year read
       # once in January keeps whatever it happened to catch. Early morning so
       # a change lands before anybody looks at a week.
       {"17 3 * * *", RintoPMO.Calendar.Worker}
     ]}
  ]

config :rinto_pmo_web,
  namespace: RintoPMOWeb,
  ecto_repos: [RintoPMO.Repo],
  generators: [context_app: :rinto_pmo, binary_id: true]

# Configures the endpoint
config :rinto_pmo_web, RintoPMOWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [json: RintoPMOWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: RintoPMO.PubSub,
  live_view: [signing_salt: "gNnKghiA"]

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

config :phoenix, :json_library, JSON

# Postgrex reaches for Jason by default, which is only here as a transitive
# development dependency: a `jsonb` column -- `message_refs.payload`, an Oban
# job's args -- would fail to encode wherever it is absent. Elixir's own JSON
# is always present and satisfies the same two-function contract.
config :postgrex, :json_library, JSON
config :phoenix, :filter_parameters, ["token"]

# of this file so it overrides the configuration defined above.
if "#{config_env()}.exs" |> Path.expand(__DIR__) |> File.exists?() do
  import_config "#{config_env()}.exs"
end

if "#{config_env()}.secret.exs" |> Path.expand(__DIR__) |> File.exists?() do
  import_config "#{config_env()}.secret.exs"
end
