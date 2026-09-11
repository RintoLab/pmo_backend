defmodule RintoPMOWeb.ErrorJSONTest do
  use ExUnit.Case, async: true

  alias RintoPMOWeb.ErrorJSON

  @errors %{
    bad_request: {400, "The request is invalid.", %{parameter: "limit", reason: "is invalid"}},
    unauthorized: {401, "The request carries no valid actor token.", %{}},
    token_not_configured:
      {401, "The server was started without RINTO_TOKEN, so it can answer nothing.", %{}},
    human_actor_missing:
      {401, "This installation has no human actor. Run `mix rinto.actors.setup_human`.", %{}},
    task_not_yours: {403, "The task is assigned to someone else.", %{assignee_id: "actor-1"}},
    not_found: {404, "The requested resource was not found.", %{}},
    proposal_not_found:
      {404, "The proposal does not belong to this document.", %{proposal_ids: ["proposal-1"]}},
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
      {409, "Something else claims this change too, and nobody has chosen between them.",
       %{proposal_id: "proposal-1", conflicting_proposal_ids: ["proposal-2"]}},
    validation_error: {422, "Request validation failed.", %{name: ["can't be blank"]}},
    unknown_block:
      {422, "The block is not part of the document's latest revision.", %{block_id: "block-1"}},
    nothing_to_commit: {422, "A publish has to name the proposals it publishes.", %{}},
    invalid_input_kind:
      {422, "The propose input is not a kind this endpoint accepts.",
       %{kind: "wormhole", allowed: ["document", "block", "title"]}},
    annotation_not_found:
      {422, "The annotation does not belong to this document.", %{annotation_id: "annotation-1"}},
    conversation_not_found:
      {422, "The topic the proposal names does not exist.", %{conversation_id: "topic-1"}},
    conversation_archived: {409, "The topic has been archived.", %{conversation_id: "topic-1"}},
    assistant_actor_required:
      {422, "The topic has no assistant configured, so nothing in it can propose.",
       %{conversation_id: "topic-1"}},
    default_assistant_missing:
      {422,
       "The default assistant does not exist, so a plain chat has no name to write under. " <>
         "Run `mix rinto.actors.setup_human`.", %{conversation_id: "topic-1"}},
    task_blocked:
      {422, "The task is blocked by unfinished dependencies.", %{blocking_tasks: ["task-1"]}},
    review_round_open:
      {422, "The document already has an open review round.", %{open_round_id: "round-1"}},
    duplicate_document:
      {422, "A document appears more than once in this commit.", %{document_id: "doc-1"}},
    invalid_block_op:
      {422, "The block operation is invalid.", %{op_index: 0, reason: "duplicate block ID"}},
    default_project_missing:
      {422, "The default project does not exist. Run `mix rinto.actors.setup_human`.",
       %{slug: "personal"}},
    invalid_markdown:
      {422, "The Markdown body could not be parsed.", %{markdown: ["is invalid"]}},
    no_change_proposed: {422, "The proposed body is the document that already exists.", %{}},
    proposal_not_live:
      {409, "The proposal has already been accepted, rejected or superseded.",
       %{proposal_ids: ["proposal-1"], statuses: ["accepted"]}},
    already_adopted:
      {409, "Another candidate for this change is already adopted.",
       %{proposal_id: "proposal-1", adopted_proposal_id: "proposal-2"}},
    needs_reconfirmation:
      {409, "The text this proposal was written against has changed. Adopt it again to confirm.",
       %{proposal_id: "proposal-1", reason: "content_diverged"}},
    proposal_not_applicable:
      {422, "The proposal cannot be applied to the document as it stands.",
       %{proposal_id: "proposal-1", reason: "target_deleted"}},
    duplicate_proposal:
      {422, "A proposal is named more than once in this publish.", %{proposal_id: "proposal-1"}},
    conflicting_selection:
      {422, "Two of the selected proposals claim the same thing.",
       %{conflicts: [%{proposal_ids: ["proposal-1", "proposal-2"], reason: "competing_text"}]}},
    unresolved_dependency:
      {422, "A selected proposal depends on something this publish does not include.",
       %{proposal_ids: ["proposal-1"]}},
    move_cycle:
      {422, "The selected moves each want to follow the other.",
       %{proposal_ids: ["proposal-1", "proposal-2"]}},
    base_revision_required: {422, "The revision this was written against has to be named.", %{}},
    unknown_revision:
      {422, "The named revision does not belong to this document.", %{revision_id: "rev-1"}},
    invalid_estimate:
      {422, "The task estimate is invalid.", %{field: "likely", reason: "must be ordered"}},
    invalid_difficulty:
      {422, "The task difficulty is invalid.",
       %{field: "difficulty", reason: "must be a Fibonacci story point (1, 2, 3, 5, 8, 13, 21)"}},
    invalid_actual:
      {422, "The recorded actual duration is invalid.",
       %{field: "actual_minutes", reason: "must be a non-negative whole number of minutes"}},
    task_not_splittable:
      {422, "The task cannot be split in its current state.", %{current_status: "done"}},
    dependency_out_of_order:
      {422, "A task cannot be scheduled before the work it is waiting for.",
       %{depends_on_id: "task-2", depends_on_planned_start_on: "2026-09-14"}},
    task_not_dependable:
      {422, "A summary node cannot take part in a dependency.", %{kind: "summary"}},
    document_not_formal:
      {422, "The document has to be adopted, and not already used, for this.", %{status: "draft"}},
    no_estimation_ai:
      {422,
       "The task estimation AI is not configured. Set it with `PUT /ai_roles/task_estimation`.",
       %{}},
    nothing_to_estimate:
      {422, "There is nothing left to estimate on this task.",
       %{kind: "difficulty", reason: "every work item already has a difficulty"}},
    no_chunks: {422, "The document has no headings, so there is no work in it to file.", %{}},
    task_before_chunk:
      {422, "A task heading stands above the first chunk heading, so it belongs to nothing.", %{}},
    corrupt_image: {422, "The image header could not be read.", %{}},
    invalid_branch: {422, "The branch name is not one git accepts.", %{branch: "--upload-pack"}},
    unknown_branch: {422, "The repository has no branch by that name.", %{branch: "nope"}},
    no_default_branch:
      {422, "The remote names no default branch. Ask for a branch by name.", %{}},
    unusable_repo_name:
      {422, "The repository name cannot be used as a directory. Rename the repository.",
       %{name: "../etc"}},
    workspace_not_configured:
      {503, "The server was started without RINTO_WORKSPACE_ROOT, so it keeps no working copies.",
       %{}},
    repo_unavailable: {503, "The repository could not be cloned. See its last_sync_error.", %{}},
    workspace_unwritable: {500, "The workspace directory could not be written.", %{}},
    too_many_references:
      {422, "Too many references in one request. Ask in smaller batches.",
       %{max: 200, given: 201}},
    unsearchable_type:
      {422, "Nothing of that kind is indexed for search.",
       %{type: "proposal", searchable: ["block", "task"]}},
    blank_query: {422, "A search needs something to search for.", %{}},
    recall_limit_too_large:
      {422, "Too many candidates to rerank in one request. Ask for a smaller recall_limit.",
       %{max: 1000, given: 5000}},
    unresolvable_references:
      {422, "The body points at things that do not exist. Check the rinto:// addresses.",
       %{uris: ["rinto://task/01936f2a-1c4e-7c3a-9f1b-2d4e6a8b0c1d"]}},
    internal_server_error: {500, "An internal server error occurred.", %{}},
    agent_unavailable:
      {503, "The agent runtime could not be started.", %{reason: ":pi_not_found"}},
    ai_not_configured:
      {503, "The server was started without RINTO_AI_TOKEN, so it cannot search.", %{}},
    ai_unavailable: {503, "The inference service could not complete the search.", %{status: 502}},
    session_limit_reached:
      {409, "Every running agent session is waiting on a person. Close one to make room.", %{}},
    codex_auth_not_pending:
      {409, "There is no pending OpenAI Codex authorization to cancel.", %{}},
    codex_auth_unavailable:
      {503, "The Pi OpenAI Codex authorization helper is unavailable.", %{}},
    not_a_preset:
      {422, "This prompt shortcut was not shipped with the system, so it has no default.", %{}},
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
