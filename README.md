# RintoPMO.Umbrella

To start your Phoenix server: 

* Run `mix setup` to install and setup dependencies
* Start Phoenix endpoint with `mix phx.server` or inside IEx with `iex -S mix phx.server` 

Now you can visit [`localhost:4000`](http://localhost:4000) from your browser.

The REST API contract is maintained in [`openapi.yaml`](openapi.yaml).

## Install the CLI

The published CLI currently supports Linux amd64 and macOS Apple Silicon. This
installs the platform-specific package atomically under the stable command name
`~/.local/bin/rinto-pmo`:

```sh
CLI_VERSION=0.2.1 # keep this aligned with cli/VERSION
case "$(uname -s)/$(uname -m)" in
  Linux/x86_64) asset=rinto-pmo-linux-amd64 ;;
  Darwin/arm64) asset=rinto-pmo-darwin-arm64 ;;
  *) echo "unsupported platform: $(uname -s)/$(uname -m)" >&2; exit 1 ;;
esac
mkdir -p "$HOME/.local/bin"
tmp="$HOME/.local/bin/.rinto-pmo.install.$$"
trap 'rm -f "$tmp"' EXIT
curl -fsSL "https://gitea.kenton.wang/api/packages/Rinto/generic/rinto-pmo/$CLI_VERSION/$asset" -o "$tmp"
chmod 0755 "$tmp"
mv -f "$tmp" "$HOME/.local/bin/rinto-pmo"
trap - EXIT
"$HOME/.local/bin/rinto-pmo" --version
```

Ensure `$HOME/.local/bin` is on `PATH`. `rinto-pmo update` downloads the right
platform asset but replaces the executable at its existing path, so the command
continues to be named `rinto-pmo`. See [`cli/README.md`](cli/README.md) for setup
and update details.

Ready to run in production? Please [check our deployment guides](https://phoenix.hexdocs.pm/deployment.html).
## Umbrella project

This is an Elixir umbrella project. It is composed of multiple apps:

* [RintoPMO](apps/rinto_pmo) - The core logic
* [RintoPMOWeb](apps/rinto_pmo_web) - The Phoenix web interface

Each app has its own README and configuration.

## Learn more

* Official website: https://www.phoenixframework.org/
* Guides: https://phoenix.hexdocs.pm/overview.html
* Docs: https://phoenix.hexdocs.pm
* Forum: https://elixirforum.com/c/phoenix-forum
* Source: https://github.com/phoenixframework/phoenix
