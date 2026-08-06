defmodule RintoPMOWeb.ErrorJSON do
  @moduledoc false

  @errors %{
    bad_request: {400, "The request is invalid."},
    not_found: {404, "The requested resource was not found."},
    image_too_large: {413, "The image exceeds the size accepted for inline use."},
    unsupported_image: {415, "The file is not an image format that can be sent to a model."},
    stale_document: {409, "The document has changed since the provided base revision."},
    task_state_conflict: {409, "The task is no longer in the expected state."},
    dependency_cycle: {409, "The task dependency would create a cycle."},
    # A contention is a question for a person, not a failure to retry, so it is
    # a conflict rather than a validation error.
    unresolved_contention: {409, "The block has competing proposals that nobody has decided."},
    validation_error: {422, "Request validation failed."},
    unknown_block: {422, "The block is not part of the document's latest revision."},
    no_live_proposal: {422, "The block has no proposal to commit."},
    nothing_to_commit: {422, "No block has a proposal ready to commit."},
    invalid_block_ids: {422, "The selected blocks are invalid."},
    proposal_not_found: {422, "The proposal is not live on that block."},
    annotation_not_found: {422, "The annotation does not belong to this document."},
    task_blocked: {422, "The task is blocked by unfinished dependencies."},
    review_round_open: {422, "The document already has an open review round."},
    invalid_block_op: {422, "The block operation is invalid."},
    invalid_estimate: {422, "The task estimate is invalid."},
    task_not_splittable: {422, "The task cannot be split in its current state."},
    corrupt_image: {422, "The image header could not be read."},
    internal_server_error: {500, "An internal server error occurred."},
    attachment_unwritable: {500, "The attachment could not be stored."},
    attachment_unreadable: {500, "The attachment bytes are missing or unreadable."}
  }

  @template_codes %{
    "400.json" => :bad_request,
    "404.json" => :not_found,
    "422.json" => :validation_error,
    "500.json" => :internal_server_error
  }

  @spec codes() :: [atom()]
  def codes, do: Map.keys(@errors)

  @spec status!(atom()) :: pos_integer()
  def status!(code) do
    {status, _message} = Map.fetch!(@errors, code)
    status
  end

  def render(template, assigns) do
    code = Map.get(assigns, :code, Map.get(@template_codes, template, :internal_server_error))
    details = Map.get(assigns, :details, %{})
    {_status, message} = Map.fetch!(@errors, code)

    %{
      error: code,
      message: message,
      details: details
    }
  end

  def template_not_found(template, assigns), do: render(template, assigns)
end
