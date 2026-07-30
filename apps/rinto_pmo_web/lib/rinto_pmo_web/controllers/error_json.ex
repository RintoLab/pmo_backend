defmodule RintoPMOWeb.ErrorJSON do
  @moduledoc false

  @errors %{
    bad_request: {400, "The request is invalid."},
    not_found: {404, "The requested resource was not found."},
    stale_document: {409, "The document has changed since the provided base version."},
    task_state_conflict: {409, "The task is no longer in the expected state."},
    dependency_cycle: {409, "The task dependency would create a cycle."},
    validation_error: {422, "Request validation failed."},
    task_blocked: {422, "The task is blocked by unfinished dependencies."},
    review_round_open: {422, "The document already has an open review round."},
    invalid_block_op: {422, "The block operation is invalid."},
    invalid_estimate: {422, "The task estimate is invalid."},
    task_not_splittable: {422, "The task cannot be split in its current state."},
    internal_server_error: {500, "An internal server error occurred."}
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
