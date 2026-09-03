# RintoPMO.Umbrella

To start your Phoenix server: 

* Run `mix setup` to install and setup dependencies
* Start Phoenix endpoint with `mix phx.server` or inside IEx with `iex -S mix phx.server` 

Now you can visit [`localhost:4000`](http://localhost:4000) from your browser.

The REST API contract is maintained in [`openapi.yaml`](openapi.yaml).

## Install the CLI

The published CLI currently supports Linux amd64 and macOS Apple Silicon. Run
the installer directly:

```sh
curl -fsSL "https://gitea.kenton.wang/api/packages/Rinto/generic/rinto-pmo/latest/install.sh" | sh
```

It detects the operating system and architecture, verifies the selected asset's
SHA-256, and atomically installs it as `~/.local/bin/rinto-pmo` without a
platform suffix. If that directory is not on `PATH`, it prints the exact export
to add to your shell profile; it does not edit profile files automatically.
Set `RINTO_INSTALL_DIR` to choose another directory or `RINTO_VERSION` to install
a specific published version. See [`cli/README.md`](cli/README.md) for setup and
update details.

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
