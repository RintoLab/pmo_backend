defmodule RintoPMO.Requirements.EstimationWorker do
  @moduledoc "Estimates missing live work in bounded batches; retries require an explicit new request."
  use Oban.Worker,
    queue: :default,
    max_attempts: 1,
    unique: [keys: [:requirement_id], period: :infinity, states: :incomplete]

  import Ecto.Query
  alias RintoPMO.AIRoles
  alias RintoPMO.Repo
  alias RintoPMO.Requirements.Estimation
  alias RintoPMO.Requirements.EstimationContext
  alias RintoPMO.Requirements.Requirement
  alias RintoPMO.Requirements.Tree
  alias RintoPMO.Tasks
  alias RintoPMO.Utils

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"requirement_id" => id}}) do
    case scope(id) do
      {:ok, requirement, tree} -> run(requirement, tree)
      {:error, reason} -> {:cancel, reason}
    end
  end

  defp run(requirement, tree) do
    targets =
      Estimation.targets(requirement.id, :difficulty) ++ Estimation.targets(requirement.id)

    if targets == [], do: :ok, else: estimate_missing(requirement, tree)
  end

  defp estimate_missing(requirement, tree) do
    with {:ok, role} <- role(),
         {:ok, context, fingerprint} <- EstimationContext.load(requirement, tree) do
      input = %{context: context, history: EstimationContext.history(requirement.project_id)}

      opts = [
        provider: role.provider,
        model: role.model,
        thinking: role.thinking_level,
        system_prompt: role.system_prompt
      ]

      estimate_dimensions(requirement, input, opts, fingerprint)
    else
      {:error, reason} -> {:cancel, reason}
    end
  end

  defp estimate_dimensions(requirement, input, opts, fingerprint) do
    Enum.reduce_while([:difficulty, :time], :ok, fn kind, :ok ->
      # Reload after difficulty writes so time estimation uses the new ratings
      # and current task versions for its conditional writes.
      targets = Estimation.targets(requirement.id, kind)

      case estimate_batches(requirement, kind, targets, input, opts, fingerprint) do
        :ok -> {:cont, :ok}
        failure -> {:halt, failure}
      end
    end)
  end

  defp estimate_batches(requirement, kind, targets, input, opts, fingerprint) do
    targets
    |> Enum.chunk_every(20)
    |> Enum.reduce_while(:ok, fn batch, :ok ->
      case estimate(requirement, kind, batch, input, opts, fingerprint) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:cancel, reason}}
      end
    end)
  end

  defp scope(id) do
    with %Requirement{} = requirement <- Repo.get(Requirement, id),
         tree = Tree.load([requirement.project_id]),
         true <- Estimation.eligible?(requirement, tree) do
      {:ok, requirement, tree}
    else
      _ -> {:error, "requirement is no longer an open leaf in an active project"}
    end
  end

  defp role do
    case AIRoles.get_role("task_estimation") do
      nil -> {:error, "the task estimation AI is not configured"}
      role -> {:ok, role}
    end
  end

  defp estimate(requirement, kind, targets, input, opts, fingerprint) do
    input =
      Map.put(
        input,
        :tasks,
        Enum.map(targets, &Map.take(&1, [:id, :title, :description, :difficulty]))
      )

    result =
      case kind do
        :difficulty ->
          Utils.module(:task_estimator).estimate_difficulty(Map.delete(input, :history), opts)

        :time ->
          Utils.module(:task_estimator).estimate_time(input, opts)
      end

    case result do
      {:ok, items} -> apply_result(requirement.id, kind, targets, items, fingerprint)
      {:error, reason} -> {:error, "AI #{kind} estimation failed: #{inspect(reason)}"}
    end
  end

  defp apply_estimates(:difficulty, targets, items),
    do: Tasks.apply_difficulty_estimates(targets, items)

  defp apply_estimates(:time, targets, items), do: Tasks.apply_time_estimates(targets, items)

  defp apply_result(id, kind, targets, items, fingerprint) do
    Repo.transact(fn ->
      Repo.one(from requirement in Requirement, where: requirement.id == ^id, lock: "FOR UPDATE")

      with {:ok, requirement, tree} <- scope(id),
           {:ok, _context, ^fingerprint} <- EstimationContext.load(requirement, tree),
           :ok <- apply_estimates(kind, targets, items) do
        {:ok, :ok}
      else
        {:error, reason} -> {:error, reason}
        _ -> {:error, "requirement or documents changed during estimation; run it again"}
      end
    end)
    |> case do
      {:ok, :ok} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end
end
