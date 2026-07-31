defmodule RintoPMOWeb.ErrorJSONTest do
  use ExUnit.Case, async: true

  alias RintoPMOWeb.ErrorJSON

  @errors %{
    bad_request: {400, "The request is invalid.", %{parameter: "limit", reason: "is invalid"}},
    not_found: {404, "The requested resource was not found.", %{}},
    stale_document:
      {409, "The document has changed since the provided base revision.",
       %{base_version: 2, current_version: 3, diff: []}},
    task_state_conflict:
      {409, "The task is no longer in the expected state.", %{current_status: "in_progress"}},
    dependency_cycle:
      {409, "The task dependency would create a cycle.", %{cycle: ["task-1", "task-2"]}},
    validation_error: {422, "Request validation failed.", %{name: ["can't be blank"]}},
    task_blocked:
      {422, "The task is blocked by unfinished dependencies.", %{blocking_tasks: ["task-1"]}},
    review_round_open:
      {422, "The document already has an open review round.", %{open_round_id: "round-1"}},
    invalid_block_op:
      {422, "The block operation is invalid.", %{op_index: 0, reason: "duplicate block ID"}},
    invalid_estimate:
      {422, "The task estimate is invalid.", %{field: "likely", reason: "must be ordered"}},
    task_not_splittable:
      {422, "The task cannot be split in its current state.", %{current_status: "done"}},
    internal_server_error: {500, "An internal server error occurred.", %{}}
  }

  for {code, {status, message, details}} <- @errors do
    test "renders the #{code} error" do
      assert ErrorJSON.status!(unquote(code)) == unquote(status)

      assert ErrorJSON.render("#{unquote(status)}.json", %{
               code: unquote(code),
               details: unquote(Macro.escape(details))
             }) == %{
               error: unquote(code),
               message: unquote(message),
               details: unquote(Macro.escape(details))
             }
    end
  end

  test "the catalog contains exactly the supported error codes" do
    assert MapSet.new(ErrorJSON.codes()) == MapSet.new(Map.keys(@errors))
  end

  test "renders errors raised outside a fallback controller" do
    assert ErrorJSON.render("404.json", %{}) == %{
             error: :not_found,
             message: "The requested resource was not found.",
             details: %{}
           }
  end

  test "falls back to an internal server error" do
    assert ErrorJSON.template_not_found("unknown.json", %{}) == %{
             error: :internal_server_error,
             message: "An internal server error occurred.",
             details: %{}
           }
  end
end
