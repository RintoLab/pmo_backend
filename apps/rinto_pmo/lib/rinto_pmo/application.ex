defmodule RintoPMO.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      RintoPMO.Repo,
      {DNSCluster, query: Application.get_env(:rinto_pmo, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: RintoPMO.PubSub}
      # Start a worker by calling: RintoPMO.Worker.start_link(arg)
      # {RintoPMO.Worker, arg}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: RintoPMO.Supervisor)
  end
end
