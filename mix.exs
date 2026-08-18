defmodule RintoPMO.Umbrella.MixProject do
  use Mix.Project

  @version File.read!(Path.join(__DIR__, "VERSION")) |> String.trim()

  def project do
    [
      apps_path: "apps",
      version: @version,
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),
      releases: releases(),
      # `:mix` is here for the one-off tasks under `apps/*/lib/mix/tasks`, which
      # call `Mix.shell/0` and would otherwise be all unknown functions.
      dialyzer: [plt_add_apps: [:ex_unit, :mix]],
      listeners: [Phoenix.CodeReloader]
    ]
  end

  def cli do
    [
      preferred_envs: [check: :test]
    ]
  end

  # Dependencies can be Hex packages:
  #
  #   {:mydep, "~> 0.3.0"}
  #
  # Or git/path repositories:
  #
  #   {:mydep, git: "https://github.com/elixir-lang/mydep.git", tag: "0.1.0"}
  #
  # Type "mix help deps" for more examples and options.
  #
  # Dependencies listed here are available only for this project
  # and cannot be accessed from applications inside the apps/ folder.
  defp deps do
    [
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:tidewave, "~> 0.8", only: [:dev]}
    ]
  end

  # Aliases are shortcuts or tasks specific to the current project.
  # For example, to install project dependencies and perform other setup tasks, run:
  #
  #     $ mix setup
  #
  # See the documentation for `Mix` for more info on aliases.
  #
  # Aliases listed here are available only for this project
  # and cannot be accessed from applications inside the apps/ folder.
  # An umbrella has to say what a release contains -- there is no single app to
  # infer it from. Both, and `rinto_pmo_web` last so the endpoint comes up after
  # what it serves.
  #
  # ERTS is included (the default), so the target machine needs no Erlang or
  # Elixir of its own. The price is that the tarball is only good for the OS,
  # architecture and libc it was built on: build on the same distribution as the
  # machine that will run it.
  # Named after the repository rather than after either OTP application, so the
  # deploy path, the systemd unit and `bin/pmo_backend` all say the same thing.
  defp releases do
    [
      pmo_backend: [
        applications: [
          rinto_pmo: :permanent,
          rinto_pmo_web: :permanent
        ]
      ]
    ]
  end

  defp aliases do
    [
      # run `mix setup` in all child apps
      setup: ["cmd mix setup"],
      check: [
        "compile --warnings-as-errors",
        "deps.unlock --unused",
        "format --check-formatted",
        "credo --strict",
        "dialyzer",
        "test"
      ]
    ]
  end
end
