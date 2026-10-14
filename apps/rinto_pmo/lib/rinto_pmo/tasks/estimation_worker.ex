defmodule RintoPMO.Tasks.EstimationWorker do
  @moduledoc """
  Runs task estimation in the background, with one attempt per explicit request.

  Incomplete jobs are deduplicated by task and estimation kind. The caller can
  poll the returned job ID; completion also broadcasts on the task channel.
  Oban's lifeline recovers abandoned jobs. Failures are not retried automatically.

  Only missing values are targeted. Both time and difficulty estimates are written
  conditionally so overlapping task/requirement jobs and manual changes cannot
  overwrite one another's results.
  """

  use Oban.Worker,
    queue: :default,
    max_attempts: 1,
    unique: [keys: [:task_id, :kind], period: :infinity, states: :incomplete]

  alias RintoPMO.Tasks

  @impl Oban.Worker
  def perform(%Oban.Job{id: id, args: %{"task_id" => task_id, "kind" => "difficulty"}}) do
    Tasks.run_estimation(id, task_id, :difficulty)
  end

  def perform(%Oban.Job{id: id, args: %{"task_id" => task_id, "kind" => "time"}}) do
    Tasks.run_estimation(id, task_id, :time)
  end
end
