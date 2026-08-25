import Config

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.

config :rinto_pmo_web, RintoPMOWeb.Endpoint,
  http: [port: String.to_integer(System.get_env("PORT", "4000"))]

# erlexec's exec-port refuses to start without SHELL, which releases running
# under systemd or Docker frequently leave unset.
if System.get_env("SHELL") in [nil, ""] do
  System.put_env("SHELL", "/bin/sh")
end

# The token every request carries. It is agreed in advance rather than issued:
# the same value goes here and into the configuration of each thing that calls
# this API, because there is no way to distribute it from here -- every client
# reads its own copy from its own file. See `RintoPMO.Actors`.
#
# Absent is a valid state and not a default-open one: a server with no token
# refuses every request, which is what an installation nobody has configured
# should do. `:test` is skipped so that a developer's own `RINTO_TOKEN` cannot
# quietly become what the suite authenticates with.
if config_env() != :test do
  config :rinto_pmo, RintoPMO.Actors, token: System.get_env("RINTO_TOKEN")
end

# The credential for the inference service in `config/config.exs`. Read here
# rather than there for the same reason `RINTO_TOKEN` is: a token committed to
# a tracked file is a token that has leaked.
#
# Absent is a valid state -- nothing is embedded, and whatever depends on that
# says so -- rather than a reason to refuse to boot. A developer without the
# service configured should still be able to run the rest of the system.
#
# Blank counts as absent. `RINTO_AI_TOKEN=` with nothing after it is what an
# environment file written from a template looks like, and an empty string is
# truthy here -- so without this the release would send `Bearer ` and read the
# service's 401 back as an outage, which is the one diagnosis that sends
# somebody to look at the wrong machine.
ai_token = "RINTO_AI_TOKEN" |> System.get_env("") |> String.trim()

if ai_token != "" do
  config :rinto_pmo, :ai, token: ai_token
end

if config_env() == :prod do
  database_url =
    System.get_env("DATABASE_URL") ||
      raise """
      environment variable DATABASE_URL is missing.
      For example: ecto://USER:PASS@HOST/DATABASE
      """

  maybe_ipv6 = if System.get_env("ECTO_IPV6") in ~w(true 1), do: [:inet6], else: []

  config :rinto_pmo, RintoPMO.Repo,
    # ssl: true,
    url: database_url,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10"),
    # For machines with several cores, consider starting multiple pools of `pool_size`
    # pool_count: 4,
    socket_options: maybe_ipv6

  # The secret key base is used to sign/encrypt cookies and other secrets.
  # A default value is used in config/dev.exs and config/test.exs but you
  # want to use a different value for prod and you most likely don't want
  # to check this value into version control, so we use an environment
  # variable instead.
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  # The origins a browser may open the socket from, which is not the same thing
  # as `url[host]` below. The frontend is served same-origin under its own name
  # and only ever talks to that one; this API answers to a different name, which
  # is what the CLI dials. `check_origin: true` -- the default -- compares the
  # `Origin` header against `url[host]` with a plain string equality, so leaving
  # it to that refuses every browser with a 403, raised inside the transport
  # before `RintoPMOWeb.PiSocket.connect/3` is ever reached.
  #
  # Only browsers send `Origin`, and a request carrying none is let through
  # whatever this says -- so the CLI is unaffected either way, and a wrong value
  # here stays invisible until the first browser opens a socket.
  #
  # Comma-separated absolute origins, each with its scheme. A leading `*.` label
  # is a suffix match, so `https://*.example.com` covers the bare name and
  # everything under it. Unset falls back to `true`, which is the case where the
  # frontend and this API answer to the same name.
  browser_origins =
    case System.get_env("BROWSER_ORIGINS") do
      empty when empty in [nil, ""] -> true
      list -> list |> String.split(",", trim: true) |> Enum.map(&String.trim/1)
    end

  config :rinto_pmo_web, RintoPMOWeb.Endpoint,
    # The external address this is reached at, through the reverse proxy in
    # front of it. Only `url/1` and verified routes read it, and this API
    # returns ids rather than links, so a wrong value is cosmetic -- but
    # `example.com` was worse than cosmetic to leave lying in the config.
    url: [host: System.get_env("PHX_HOST") || "localhost", port: 443, scheme: "https"],
    check_origin: browser_origins,
    http: [
      # All interfaces, and it has to stay that way: the reverse proxy in front
      # of this connects from off the box. Loopback here would answer the
      # deploy's own health check and nothing else, which is the worst shape a
      # misconfiguration can take -- green pipeline, dead service.
      #
      # This is the IPv6 wildcard, which accepts IPv4 too on any system with
      # `net.ipv6.bindv6only=0` (the default on Debian and Ubuntu). If the proxy
      # can reach the port but gets connection refused, that setting is the
      # first thing to check; `{0, 0, 0, 0}` forces IPv4-only.
      ip: {0, 0, 0, 0, 0, 0, 0, 0}
    ],
    secret_key_base: secret_key_base,
    # A release does not run `mix phx.server`, so nothing else would ever tell
    # the endpoint to listen. Without this the release boots, stays up, and
    # answers nothing -- which looks exactly like a network problem.
    server: true

  # ## SSL Support
  #
  # To get SSL working, you will need to add the `https` key
  # to your endpoint configuration:
  #
  #     config :rinto_pmo_web, RintoPMOWeb.Endpoint,
  #       https: [
  #         ...,
  #         port: 443,
  #         cipher_suite: :strong,
  #         keyfile: System.get_env("SOME_APP_SSL_KEY_PATH"),
  #         certfile: System.get_env("SOME_APP_SSL_CERT_PATH")
  #       ]
  #
  # The `cipher_suite` is set to `:strong` to support only the
  # latest and more secure SSL ciphers. This means old browsers
  # and clients may not be supported. You can set it to
  # `:compatible` for wider support.
  #
  # `:keyfile` and `:certfile` expect an absolute path to the key
  # and cert in disk or a relative path inside priv, for example
  # "priv/ssl/server.key". For all supported SSL configuration
  # options, see https://plug.hexdocs.pm/Plug.SSL.html#configure/1
  #
  # We also recommend setting `force_ssl` in your config/prod.exs,
  # ensuring no data is ever sent via http, always redirecting to https:
  #
  #     config :rinto_pmo_web, RintoPMOWeb.Endpoint,
  #       force_ssl: [hsts: true]
  #
  # Check `Plug.SSL` for all available options in `force_ssl`.

  config :rinto_pmo, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")
end
