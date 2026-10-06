defmodule RintoPMOWeb.ErrorJSON do
  @moduledoc false

  @errors %{
    bad_request: {400, "The request is invalid."},
    unauthorized: {401, "The request carries no valid actor token."},
    # Told apart from a wrong token deliberately. Both describe an operator's
    # problem rather than a caller's, and neither gives anything away: a server
    # with no token configured, and one with no person to be, have nothing in
    # them to protect.
    token_not_configured:
      {401, "The server was started without RINTO_TOKEN, so it can answer nothing."},
    human_actor_missing:
      {401, "This installation has no human actor. Run `mix rinto.actors.setup_human`."},
    # Authenticated, and refused anyway. The only 403 in the catalog, and it is
    # one on purpose: every other refusal here is about the request or the state
    # of a thing, while this one is about who is asking. Told apart from
    # `task_already_claimed` because they answer differently -- losing a race
    # means pick another task, and this means the id was wrong or the work was
    # never yours to move.
    task_not_yours: {403, "The task is assigned to someone else."},
    not_found: {404, "The requested resource was not found."},
    # An id that names nothing, or names something in another document. A 404
    # rather than a validation error: the request is well formed and the thing
    # it asks for is simply not there.
    proposal_not_found: {404, "The proposal does not belong to this document."},
    image_too_large: {413, "The image exceeds the size accepted for inline use."},
    unsupported_image: {415, "The file is not an image format that can be sent to a model."},
    task_sync_conflict:
      {409, "Task synchronization conflicts with existing work. No tasks were changed."},
    stale_document: {409, "The document has changed since the provided base revision."},
    no_prioritization_ai:
      {422,
       "The requirement priority AI is not configured. Set it with PUT /ai_roles/requirement_prioritization."},
    task_state_conflict: {409, "The task is no longer in the expected state."},
    # Losing a claim race is not a validation failure and not a retry: the task
    # has an owner now, and the answer is to pick a different one.
    task_already_claimed: {409, "The task has already been claimed by someone else."},
    dependency_cycle: {409, "The task dependency would create a cycle."},
    # A contention is a question for a person, not a failure to retry, so it is
    # a conflict rather than a validation error.
    unresolved_contention:
      {409, "Something else claims this change too, and nobody has chosen between them."},
    # Never resolved by retrying: a session parked on a question is waiting on
    # a person, and is never evicted to make room.
    session_limit_reached:
      {409, "Every running agent session is waiting on a person. Close one to make room."},
    codex_auth_not_pending: {409, "There is no pending OpenAI Codex authorization to cancel."},
    validation_error: {422, "Request validation failed."},
    unknown_block: {422, "The block is not part of the document's latest revision."},
    nothing_to_commit: {422, "A publish has to name the proposals it publishes."},
    invalid_input_kind: {422, "The propose input is not a kind this endpoint accepts."},
    annotation_not_found: {422, "The annotation does not belong to this document."},
    conversation_not_found: {422, "The topic the proposal names does not exist."},
    # Put away, not missing. GET still finds it; a further turn does not.
    conversation_archived: {409, "The topic has been archived."},
    assistant_actor_required:
      {422, "The topic has no assistant configured, so nothing in it can propose."},
    # The plain-chat half of the same question: the topic is configured, but
    # what it is configured with is a model rather than an actor, so writing
    # from it is signed with the default actor -- and this installation has
    # none, which means setup never ran.
    default_assistant_missing:
      {422,
       "The default assistant does not exist, so a plain chat has no name to " <>
         "write under. Run `mix rinto.actors.setup_human`."},
    task_blocked: {422, "The task is blocked by unfinished dependencies."},
    review_round_open: {422, "The document already has an open review round."},
    invalid_block_op: {422, "The block operation is invalid."},
    invalid_markdown: {422, "The Markdown body could not be parsed."},
    # A document with no project of its own has nowhere to go. The reserved
    # slug has been renamed, or the setup task was never run.
    default_project_missing:
      {422, "The default project does not exist. Run `mix rinto.actors.setup_human`."},
    no_change_proposed: {422, "The proposed body is the document that already exists."},
    # Already decided, one way or another. A conflict rather than a validation
    # error: the request was well formed and would have been fine a moment ago.
    proposal_not_live: {409, "The proposal has already been accepted, rejected or superseded."},
    # Somebody has already chosen among these candidates and that choice still
    # refers to what it was made about. Taking it away is `unadopt`, said out
    # loud, rather than something an adopt does on its way past.
    already_adopted: {409, "Another candidate for this change is already adopted."},
    # The words this proposal was written against have changed. Not a failure to
    # retry: the answer is to look at the new comparison and choose again.
    needs_reconfirmation:
      {409, "The text this proposal was written against has changed. Adopt it again to confirm."},
    # Nothing to apply it to, or nothing left for it to do. `details.reason`
    # says which, because "delete a block that is already gone" and "update a
    # block that no longer exists" call for different next steps.
    proposal_not_applicable:
      {422, "The proposal cannot be applied to the document as it stands."},
    duplicate_proposal: {422, "A proposal is named more than once in this publish."},
    # Two selected proposals that cannot both be true. Refused rather than
    # ordered: picking one of them is the decision this system leaves to a
    # person, and doing it here would do it invisibly.
    conflicting_selection: {422, "Two of the selected proposals claim the same thing."},
    # A selected change needs something the selection leaves out -- a move whose
    # destination this same publish removes.
    unresolved_dependency:
      {422, "A selected proposal depends on something this publish does not include."},
    move_cycle: {422, "The selected moves each want to follow the other."},
    # Never inferred. A body written against a revision nobody named could be
    # anything, and stamping the latest one onto it would turn a stale rewrite
    # into a silent revert.
    base_revision_required: {422, "The revision this was written against has to be named."},
    unknown_revision: {422, "The named revision does not belong to this document."},
    invalid_estimate: {422, "The task estimate is invalid."},
    invalid_difficulty: {422, "The task difficulty is invalid."},
    invalid_actual: {422, "The recorded actual duration is invalid."},
    # Scheduling a task ahead of work it waits for. Carries both ends and both
    # days, because "which one do I move" is the next question either way.
    dependency_out_of_order:
      {422, "A task cannot be scheduled before the work it is waiting for."},
    # Filing a document as a work breakdown, and adopting one. Both ends of the
    # same axis: a document has to be adopted before it can be filed, and a
    # document already filed cannot be filed again.
    document_not_formal: {422, "The document has to be adopted, and not already used, for this."},
    # Estimating. It belongs to no conversation, so an unconfigured role is a
    # refusal rather than a fallback -- there is nothing to fall back to.
    no_estimation_ai:
      {422,
       "The task estimation AI is not configured. Set it with `PUT /ai_roles/task_estimation`."},
    nothing_to_estimate: {422, "There is nothing left to estimate on this task."},
    # A shortcut somebody created through the API has no default wording to be
    # put back to: nobody but its author ever chose one.
    not_a_preset:
      {422, "This prompt shortcut was not shipped with the system, so it has no default."},
    # One document named twice in one batch commit. Two ideas about what a
    # single commit is, and the second would be against a revision the first
    # had just replaced.
    duplicate_document: {422, "A document appears more than once in this commit."},
    # Both mean the document is not the shape a breakdown is, which is a thing
    # to fix in the document.
    no_chunks: {422, "The document has no headings, so there is no work in it to file."},
    task_before_chunk:
      {422, "A task heading stands above the first chunk heading, so it belongs to nothing."},
    corrupt_image: {422, "The image header could not be read."},
    # Asked to resolve more references than one request carries. Refused rather
    # than truncated: a caller handed back half its links would render the rest
    # as broken, which reads as data loss instead of a limit.
    too_many_references: {422, "Too many references in one request. Ask in smaller batches."},
    # Asked to search a kind of thing nothing is indexed under. Said rather than
    # answered with an empty list: the question could never have found anything,
    # which is a mistake in the request rather than a result.
    unsearchable_type: {422, "Nothing of that kind is indexed for search."},
    # A body pointing at something that is not there. The offending addresses
    # come back in `details.uris` so that whoever wrote them can fix those
    # rather than re-read the whole document.
    # An empty query embeds to a vector like any other string, and that vector
    # has neighbours -- so the alternative to refusing is a list ordered by
    # nothing, which looks like an answer. Browsing is a different endpoint.
    blank_query: {422, "A search needs something to search for."},
    # Asked to rerank more candidates than one request carries. Refused rather
    # than clamped: the point of naming a depth is to compare it against
    # another, and a caller quietly given a different one draws the wrong
    # conclusion from the results.
    recall_limit_too_large:
      {422, "Too many candidates to rerank in one request. Ask for a smaller recall_limit."},
    unresolvable_references:
      {422, "The body points at things that do not exist. Check the rinto:// addresses."},
    # Asking for a branch of a repository. The first two are the request being
    # wrong about the repository; the last two are the repository being wrong
    # about itself, and are the cases here nobody can fix from the request.
    invalid_branch: {422, "The branch name is not one git accepts."},
    unknown_branch: {422, "The repository has no branch by that name."},
    # A checkout that named no branch falls back to the remote's default, and
    # this remote names none. Nothing about the repository can be changed to
    # fix it; naming a branch can, and only the caller can do that.
    no_default_branch: {422, "The remote names no default branch. Ask for a branch by name."},
    unusable_repo_name:
      {422, "The repository name cannot be used as a directory. Rename the repository."},
    internal_server_error: {500, "An internal server error occurred."},
    agent_unavailable: {503, "The agent runtime could not be started."},
    codex_auth_unavailable: {503, "The Pi OpenAI Codex authorization helper is unavailable."},
    # Searching without the service that does the searching. Told apart from
    # `ai_unavailable` for the same reason `token_not_configured` is told apart
    # from `unauthorized`: this one is an installation nobody finished
    # configuring, and no amount of retrying will change it.
    ai_not_configured:
      {503, "The server was started without RINTO_AI_TOKEN, so it cannot search."},
    ai_unavailable: {503, "The inference service could not complete the search."},
    # Asked for a working copy on a server that keeps none. Told apart from
    # `repo_unavailable` for the same reason `ai_not_configured` is told apart
    # from `ai_unavailable`: this one is an installation nobody finished
    # configuring, and no amount of retrying will change it.
    workspace_not_configured:
      {503, "The server was started without RINTO_WORKSPACE_ROOT, so it keeps no working copies."},
    # A repository that has never been cloned and could not be. `details` do not
    # carry git's own words: `last_sync_error` on the repository does, and it
    # survives the request.
    repo_unavailable: {503, "The repository could not be cloned. See its last_sync_error."},
    workspace_unwritable: {500, "The workspace directory could not be written."},
    attachment_unwritable: {500, "The attachment could not be stored."},
    attachment_unreadable: {500, "The attachment bytes are missing or unreadable."}
  }

  @template_codes %{
    "400.json" => :bad_request,
    "401.json" => :unauthorized,
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
