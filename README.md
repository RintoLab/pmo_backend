# RintoPMO.Umbrella

To start your Phoenix server: 

* Run `mix setup` to install and setup dependencies
* Start Phoenix endpoint with `mix phx.server` or inside IEx with `iex -S mix phx.server` 

Now you can visit [`localhost:4000`](http://localhost:4000) from your browser.

The REST API contract is maintained in [`openapi.yaml`](openapi.yaml).

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
