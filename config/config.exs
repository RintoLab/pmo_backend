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
    documents: RintoPMO.Documents,
    projects: RintoPMO.Projects,
    repo_credentials: RintoPMO.RepoCredentials,
    # Each layer of pi model discovery, so a test of one mocks the next.
    rpc: RintoPMO.Agent.Rpc,
    os_process: RintoPMO.OSProcess
  ]

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

config :rinto_pmo, RintoPMO.Agent.PromptBuilder,
  # Characters of block content inlined per referenced document before the rest
  # is elided.
  max_document_chars: 20_000,
  # Documents listed in a project reference's index.
  max_project_documents: 50

config :rinto_pmo, RintoPMO.OSProcess,
  # Seconds between SIGTERM and SIGKILL when stopping a child.
  kill_timeout: 5,
  # Milliseconds to keep collecting output after a child exits.
  drain_timeout: 25,
  # Under `framing: :lines`, cap the pending partial line at this many bytes so
  # a child that never emits a newline cannot grow the buffer without bound.
  # Unbounded by default: cutting a line is lossy, so it is opt-in per child.
  max_line_bytes: :infinity

config :rinto_pmo, Oban,
  repo: RintoPMO.Repo,
  queues: [default: 10]

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
config :phoenix, :filter_parameters, ["token"]

# of this file so it overrides the configuration defined above.
if "#{config_env()}.exs" |> Path.expand(__DIR__) |> File.exists?() do
  import_config "#{config_env()}.exs"
end

if "#{config_env()}.secret.exs" |> Path.expand(__DIR__) |> File.exists?() do
  import_config "#{config_env()}.secret.exs"
end
