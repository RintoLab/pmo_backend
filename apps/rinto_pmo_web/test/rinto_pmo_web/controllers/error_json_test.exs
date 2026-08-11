defmodule RintoPMOWeb.ErrorJSONTest do
  use ExUnit.Case, async: true

  alias RintoPMOWeb.ErrorJSON

  @errors %{
    bad_request: {400, "The request is invalid.", %{parameter: "limit", reason: "is invalid"}},
    not_found: {404, "The requested resource was not found.", %{}},
    image_too_large:
      {413, "The image exceeds the size accepted for inline use.",
       %{byte_size: 9_000_000, limit: 4_500_000}},
    unsupported_image:
      {415, "The file is not an image format that can be sent to a model.",
       %{supported: ["image/png", "image/jpeg"]}},
    stale_document:
      {409, "The document has changed since the provided base revision.",
       %{base_version: 2, current_version: 3, diff: []}},
    task_state_conflict:
      {409, "The task is no longer in the expected state.", %{current_status: "in_progress"}},
    task_already_claimed:
      {409, "The task has already been claimed by someone else.",
       %{assignee_id: "actor-1", status: "open"}},
    dependency_cycle:
      {409, "The task dependency would create a cycle.", %{cycle: ["task-1", "task-2"]}},
    unresolved_contention:
      {409, "The block has competing proposals that nobody has decided.",
       %{block_ids: ["block-1"]}},
    validation_error: {422, "Request validation failed.", %{name: ["can't be blank"]}},
    unknown_block:
      {422, "The block is not part of the document's latest revision.", %{block_id: "block-1"}},
    no_live_proposal: {422, "The block has no proposal to commit.", %{block_id: "block-1"}},
    nothing_to_commit: {422, "Nothing has a proposal ready to commit.", %{}},
    invalid_block_ids:
      {422, "The selected blocks are invalid.", %{reason: "block_ids must be an array"}},
    proposal_not_found:
      {422, "The proposal is not live in that slot.",
       %{proposal_id: "proposal-1", block_id: "block-1"}},
    invalid_scope:
      {422, "The proposal scope is not one this endpoint accepts.",
       %{scope: "wormhole", allowed: ["block", "title"]}},
    annotation_not_found:
      {422, "The annotation does not belong to this document.", %{annotation_id: "annotation-1"}},
    task_blocked:
      {422, "The task is blocked by unfinished dependencies.", %{blocking_tasks: ["task-1"]}},
    review_round_open:
      {422, "The document already has an open review round.", %{open_round_id: "round-1"}},
    invalid_block_op:
      {422, "The block operation is invalid.", %{op_index: 0, reason: "duplicate block ID"}},
    invalid_markdown:
      {422, "The Markdown body could not be parsed.", %{markdown: ["is invalid"]}},
    no_change_proposed: {422, "The proposed body is the document that already exists.", %{}},
    stale_proposal:
      {409, "The whole-document proposal was written against an older revision. Propose again.",
       %{proposal_id: "proposal-1", base_revision_id: "rev-1", current_revision_id: "rev-2"}},
    conflicting_commit:
      {422, "A whole-document proposal is committed on its own, not with a block selection.", %{}},
    invalid_estimate:
      {422, "The task estimate is invalid.", %{field: "likely", reason: "must be ordered"}},
    task_not_splittable:
      {422, "The task cannot be split in its current state.", %{current_status: "done"}},
    corrupt_image: {422, "The image header could not be read.", %{}},
    internal_server_error: {500, "An internal server error occurred.", %{}},
    agent_unavailable:
      {503, "The agent runtime could not be started.", %{reason: ":pi_not_found"}},
    session_limit_reached:
      {409, "Every running agent session is waiting on a person. Close one to make room.", %{}},
    attachment_unwritable: {500, "The attachment could not be stored.", %{reason: "enospc"}},
    attachment_unreadable:
      {500, "The attachment bytes are missing or unreadable.", %{reason: "enoent"}}
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
