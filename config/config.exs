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
  injectors: [actors: RintoPMO.Actors]

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

# of this file so it overrides the configuration defined above.
if "#{config_env()}.exs" |> Path.expand(__DIR__) |> File.exists?() do
  import_config "#{config_env()}.exs"
end

if "#{config_env()}.secret.exs" |> Path.expand(__DIR__) |> File.exists?() do
  import_config "#{config_env()}.secret.exs"
end
