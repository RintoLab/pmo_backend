defmodule RintoPMO.Tasks.EstimationWorker do
  @moduledoc """
  Runs one estimation off the request path.

  ## Why a queue and not a task

  The model call takes as long as it takes. Doing it inline would hold a
  request open for a minute; doing it in an unsupervised task would leave the
  client holding nothing it could ask about later. A job has an id, and that
  id is the whole of what a client keeps: it is what it hands to
  `GET /jobs/{id}` when it comes back and wants to know whether the thing it
  started is still going.

  ## The job row is the only row

  There is no attempt table. What an estimation leaves behind is the numbers
  on the tasks; the *asking* needs to survive only as long as somebody might
  ask about it, which is exactly as long as the queue keeps the job. When the
  job is pruned away, the answer is already on the task and there is nothing
  the missing row would have added.

  ## One attempt, and then it is over

  `max_attempts: 1`, and a failed model call comes back as `{:cancel, reason}`
  rather than an error. Both say the same thing: this is finished. Retrying
  would ask the identical question of the identical model and cost the
  identical money, and nineteen more times is the default if nobody says
  otherwise.

  Somebody who thinks it was worth another go clicks again. That is a person
  deciding, which is the right kind of retry for a call this expensive.

  ## Uniqueness is a debounce, not a lock

  Over `:incomplete` states and over `(task_id, kind)`: while one is in flight,
  a second ask gets handed the job already queued instead of starting a second
  model call.

  It is worth being exact about what this buys, because it is not correctness.
  Two of these running at once would not corrupt anything: each holds the
  tasks it read when it started, both write, the later one wins, and the value
  that lands is one of two answers to the same question. What the debounce
  saves is a second `pi` process and a second minute of waiting, and it stops
  the number a person is watching from landing on 5 and then jumping to 8.

  `period: :infinity` rather than a window, because the thing being waited on
  is the job finishing, not a clock. A finite period would let a second ask
  through while the first was still talking to the model, which is the one
  case this exists for.

  It follows that `:incomplete` has to actually be transient. Nothing here
  makes it so -- `Oban.Plugins.Lifeline`, in `config/config.exs`, does. Without
  it a job orphaned in `executing` holds this slot forever and the task can
  never be estimated again.

  What it does not cover: a summary and something under it, asked separately,
  both estimating the same work item. Those are different `task_id`s, so both
  run. That is the same harmless race as above, and closing it would mean
  keying on the work rather than on the request, which is a lock, and this is
  not one.

  Asking again *after* one has finished is allowed and makes a new job. It may
  overwrite what the last one wrote, and that is fine -- neither answer claims
  to be the better one, and the person who wanted the first one kept can type
  it in, which is what the field was always for.
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
