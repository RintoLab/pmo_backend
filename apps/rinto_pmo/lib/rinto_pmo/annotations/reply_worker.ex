defmodule RintoPMO.Annotations.ReplyWorker do
  @moduledoc """
  Runs one AI reply to one annotation, off the request path.

  Built the same way as `RintoPMO.Tasks.EstimationWorker`, and the reasoning
  carries over without change.

  ## The job row is the only row

  There is no attempt table. What this leaves behind is the reply, sitting in
  the thread like any other; the *asking* needs to survive only as long as
  somebody might ask about it, which is exactly as long as the queue keeps the
  job. When it is pruned the answer is already on the annotation.

  ## One attempt, and then it is over

  `max_attempts: 1`, and a failed model call comes back as `{:cancel, reason}`.
  Both say the same thing: this is finished. Retrying asks the identical
  question of the identical model at the identical cost, nineteen more times
  by default. Somebody who thinks it was worth another go clicks again, which
  is a person deciding -- the right kind of retry for a call this expensive.

  ## Uniqueness is a debounce, not a lock

  Over `:incomplete` states and over `annotation_id`: while one reply is in
  flight, a second ask is handed the job already queued instead of starting a
  second model call. It is not correctness -- two replies to one note would be
  two rows in a list that is already a list, which is harmless. What it saves
  is a second `pi` process and a second minute, and it stops one double-click
  reading as two opinions.

  `period: :infinity` rather than a window, because what is being waited on is
  the job finishing and not a clock.
  """

  use Oban.Worker,
    queue: :default,
    max_attempts: 1,
    unique: [keys: [:annotation_id], period: :infinity, states: :incomplete]

  alias RintoPMO.Utils

  @impl Oban.Worker
  def perform(%Oban.Job{id: id, args: %{"annotation_id" => annotation_id}}) do
    Utils.module(:annotations).run_reply(id, annotation_id)
  end
end
