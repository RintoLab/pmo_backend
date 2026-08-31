defmodule RintoPMO.Annotations.ReviewWorker do
  @moduledoc """
  Runs one AI review of one set of documents, off the request path.

  Built the same way as `RintoPMO.Annotations.ReplyWorker`, and everything that
  module says carries over: the job row is the only row, one attempt and then
  it is over, and the uniqueness is a debounce rather than a lock. What it
  leaves behind is annotations, sitting on the documents like any other.

  ## The set is the key

  Uniqueness is over `document_ids`, which `RintoPMO.Annotations.request_review/1`
  sorts before handing over. Two clicks on the same selection are one review
  however the client happened to order the list, and a *different* selection --
  even one overlapping this one -- is a different question and runs.

  Reviewing one document twice in two overlapping sets is therefore possible.
  That is allowed for the same reason asking twice is: the second answer was
  asked for by somebody who wanted it.
  """

  use Oban.Worker,
    queue: :default,
    max_attempts: 1,
    unique: [keys: [:document_ids], period: :infinity, states: :incomplete]

  alias RintoPMO.Utils

  @impl Oban.Worker
  def perform(%Oban.Job{id: id, args: %{"document_ids" => document_ids}}) do
    Utils.module(:annotations).run_review(id, document_ids)
  end
end
