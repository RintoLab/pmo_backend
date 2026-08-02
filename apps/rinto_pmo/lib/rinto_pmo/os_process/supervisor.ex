defmodule RintoPMO.OSProcess.Supervisor do
  @moduledoc false

  # Groups the registry and the dynamic supervisor backing `RintoPMO.OSProcess`.
  #
  # `:rest_for_one` matters here: if the registry died under a `:one_for_one`
  # parent, the dynamic supervisor would survive holding instances whose `:via`
  # names no longer resolve -- permanently unreachable. Tying them together
  # means a registry restart rebuilds the instances too.

  use Supervisor

  @doc false
  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    children = [
      {Registry, keys: :unique, name: RintoPMO.OSProcess.Registry},
      {DynamicSupervisor, name: RintoPMO.OSProcess.DynamicSupervisor, strategy: :one_for_one}
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end
end
