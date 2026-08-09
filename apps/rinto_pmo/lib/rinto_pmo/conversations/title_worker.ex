defmodule RintoPMO.Conversations.TitleWorker do
  @moduledoc """
  Runs `RintoPMO.Conversations.Titles.name/1` off the prompt path.

  ## Why a queue and not a task

  Naming involves a model call, and a model call takes as long as it takes.
  Doing it inline would hold up the answer the person is actually waiting for;
  doing it in an unsupervised task would lose it whenever the node restarts
  mid-call -- and a topic that missed its one chance to be named stays "未命名
  话题" forever, since nothing tries again.

  ## Once per topic

  Uniqueness is on `conversation_id` and covers completed jobs, so the second
  message of a conversation cannot queue a second naming. That is an
  optimisation, not the guarantee: jobs are pruned eventually, and two nodes
  can insert either side of the same check. The guarantee is
  `Titles.apply_title/2`, which writes only while the topic is still unnamed --
  so a duplicate job costs one wasted model call and changes nothing.

  A model failure is not a job failure. `Titles.name/1` falls back to a title
  built from the message itself, so retrying would only ask a broken provider
  the same question again while the topic already has a name.
  """

  use Oban.Worker,
    queue: :default,
    max_attempts: 3,
    unique: [keys: [:conversation_id], period: :infinity, states: :successful]

  alias RintoPMO.Conversations.Titles

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"conversation_id" => conversation_id}}) do
    # `:ignore` (already named, or nothing said yet) and `:stale` (somebody
    # named it first) are both the system working. Neither is retried: the
    # conversation is in the state it should be in.
    _outcome = Titles.name(conversation_id)
    :ok
  end

  @impl Oban.Worker
  def timeout(_job), do: :timer.minutes(2)
end
