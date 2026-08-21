defmodule RintoPMO.Documents.DecompositionWorker do
  @moduledoc """
  Runs one decomposition off the request path.

  ## Why a queue and not a task

  The model call takes as long as it takes. Doing it inline would hold a
  request open for a minute; doing it in an unsupervised task would lose it
  whenever the node restarts mid-call, and an attempt stuck at `:running`
  forever is worse than one that failed -- it holds the in-flight slot, so the
  document can never be broken down again.

  ## Retries are the queue's business and nothing else's

  There is no bespoke retry judgement here -- no telling "the document did not
  fit" from "the provider is rate limiting" -- because that would mean parsing
  a provider's prose, which drifts. The attempt is binary: it succeeds or it is
  written down as failed, and `RintoPMO.Documents.run_decomposition/1` answers
  `:ok` either way so a recorded failure is not also a queue failure.

  Somebody who thinks it was worth another go clicks again, which makes a new
  attempt. That is a person deciding, which is the right kind of retry for a
  call this expensive.

  ## Uniqueness is per run, not per document

  Deliberately unlike `RintoPMO.Conversations.TitleWorker`, whose uniqueness
  covers *completed* jobs because a topic is named once and never again. A
  document can be broken down again -- after the first breakdown is archived,
  or after an attempt failed -- and copying that would mean the second attempt
  silently never ran.

  So uniqueness here is over `:incomplete` and does one small thing: stop the
  same attempt being enqueued twice. What stops a second *concurrent* attempt
  on the same document is the partial unique index on the table, which is the
  only place two simultaneous clicks can be told apart.
  """

  use Oban.Worker,
    queue: :default,
    unique: [keys: [:decomposition_id], period: :infinity, states: :incomplete]

  alias RintoPMO.Documents
  alias RintoPMO.Documents.Decomposition
  alias RintoPMO.Repo

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"decomposition_id" => decomposition_id}}) do
    case Repo.get(Decomposition, decomposition_id) do
      # The source document was deleted, taking the attempt with it. Nothing to
      # run and nobody to tell.
      nil -> :ok
      decomposition -> Documents.run_decomposition(decomposition)
    end
  end
end
