defmodule RintoPMO.Requirements.PrioritizationWorker do
  @moduledoc false
  use Oban.Worker,
    queue: :default,
    max_attempts: 1,
    unique: [keys: [:requirement_id], period: :infinity, states: :incomplete]

  alias RintoPMO.Requirements.Prioritization

  @impl Oban.Worker
  def perform(job) do
    case Prioritization.run(job) do
      :ok -> :ok
      {:error, reason} -> {:cancel, inspect(reason)}
      {:error, code, details} -> {:cancel, inspect({code, details})}
    end
  end
end
