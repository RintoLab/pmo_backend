import Config

# The external address, for the one thing it is used for: `url[host]` is what
# `Phoenix.VerifiedRoutes` and `url/1` build absolute URLs from. This API never
# generates one -- it returns ids, not links -- so this is hygiene rather than
# load-bearing. Set at runtime from `PHX_HOST`; see `config/runtime.exs`.
#
# No `cache_static_manifest`: there are no static assets. The endpoint serves
# JSON under `/api/v1` and nothing else, and there is no asset pipeline in
# `mix.exs` to digest.

# No `force_ssl` either, deliberately.
#
# A reverse proxy sits in front of this and terminates TLS; the release serves
# plain HTTP on the loopback side of it. `force_ssl` would put Plug.SSL in the
# way of that, and Plug.SSL only knows a request was secure if the proxy says so
# with `x-forwarded-proto`. A proxy that does not set that header -- which is
# every plain-HTTP intranet hop -- gets every request answered with a 301 to
# `https://<url[host]>` instead of an answer.
#
# It is also compile-time, so it cannot be switched off per deployment: a build
# with it on is a build that needs that header everywhere it is ever installed.
# TLS and HSTS belong to whatever terminates TLS, which is not this.

# Do not print debug messages in production
config :logger, level: :info

# Runtime production configuration, including reading
# of environment variables, is done on config/runtime.exs.
