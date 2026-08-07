import Config

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :rinto_pmo, RintoPMO.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  database: "rinto_pmo_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

config :rinto_pmo, :injectors,
  actors: RintoPMO.ActorsMock,
  annotations: RintoPMO.AnnotationsMock,
  attachments: RintoPMO.AttachmentsMock,
  conversations: RintoPMO.ConversationsMock,
  documents: RintoPMO.DocumentsMock,
  projects: RintoPMO.ProjectsMock,
  repo_credentials: RintoPMO.RepoCredentialsMock,
  rpc: RintoPMO.Agent.RpcMock,
  os_process: RintoPMO.OSProcessMock

# Uploads land in a scratch directory: tests write real files, and the project
# tree should not collect them.
config :rinto_pmo, RintoPMO.Attachments,
  root:
    Path.join(
      System.tmp_dir!(),
      "rinto-pmo-attachments-test#{System.get_env("MIX_TEST_PARTITION")}"
    )

# Keeps the application's own catalog off pi. Tests that exercise discovery
# start a catalog of their own with a `:discover` of their choosing.
config :rinto_pmo, RintoPMO.Agent.ModelCatalog, load_on_start: false

# Shorter SIGTERM grace so kill/stop tests finish quickly.
config :rinto_pmo, RintoPMO.OSProcess, kill_timeout: 1, drain_timeout: 25

config :rinto_pmo, Oban, testing: :manual, queues: false, plugins: false

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :rinto_pmo_web, RintoPMOWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "wyKtLkZb6+UMmL2WyZQvFhhQ4naR37ZNq2ON76Zaa6geaGOMc1E0HghHwKp+2ouy",
  server: false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true
