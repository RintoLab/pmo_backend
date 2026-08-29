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
    image_too_large: {413, "The image exceeds the size accepted for inline use."},
    unsupported_image: {415, "The file is not an image format that can be sent to a model."},
    stale_document: {409, "The document has changed since the provided base revision."},
    task_state_conflict: {409, "The task is no longer in the expected state."},
    # Losing a claim race is not a validation failure and not a retry: the task
    # has an owner now, and the answer is to pick a different one.
    task_already_claimed: {409, "The task has already been claimed by someone else."},
    dependency_cycle: {409, "The task dependency would create a cycle."},
    # A contention is a question for a person, not a failure to retry, so it is
    # a conflict rather than a validation error.
    unresolved_contention: {409, "The block has competing proposals that nobody has decided."},
    # Never resolved by retrying: a session parked on a question is waiting on
    # a person, and is never evicted to make room.
    session_limit_reached:
      {409, "Every running agent session is waiting on a person. Close one to make room."},
    validation_error: {422, "Request validation failed."},
    unknown_block: {422, "The block is not part of the document's latest revision."},
    no_live_proposal: {422, "The block has no proposal to commit."},
    nothing_to_commit: {422, "Nothing has a proposal ready to commit."},
    invalid_block_ids: {422, "The selected blocks are invalid."},
    proposal_not_found: {422, "The proposal is not live in that slot."},
    invalid_scope: {422, "The proposal scope is not one this endpoint accepts."},
    annotation_not_found: {422, "The annotation does not belong to this document."},
    conversation_not_found: {422, "The topic the proposal names does not exist."},
    assistant_actor_required:
      {422, "The topic has no assistant configured, so nothing in it can propose."},
    task_blocked: {422, "The task is blocked by unfinished dependencies."},
    review_round_open: {422, "The document already has an open review round."},
    invalid_block_op: {422, "The block operation is invalid."},
    invalid_markdown: {422, "The Markdown body could not be parsed."},
    # A document with no project of its own has nowhere to go. The reserved
    # slug has been renamed, or the setup task was never run.
    default_project_missing:
      {422, "The default project does not exist. Run `mix rinto.actors.setup_human`."},
    no_change_proposed: {422, "The proposed body is the document that already exists."},
    stale_proposal:
      {409, "The whole-document proposal was written against an older revision. Propose again."},
    conflicting_commit:
      {422, "A whole-document proposal is committed on its own, not with a block selection."},
    rebase_conflict:
      {409, "The proposal cannot be carried across what landed under it without a decision."},
    invalid_estimate: {422, "The task estimate is invalid."},
    invalid_difficulty: {422, "The task difficulty is invalid."},
    invalid_actual: {422, "The recorded actual duration is invalid."},
    task_not_splittable: {422, "The task cannot be split in its current state."},
    # Scheduling a task ahead of work it waits for. Carries both ends and both
    # days, because "which one do I move" is the next question either way.
    dependency_out_of_order:
      {422, "A task cannot be scheduled before the work it is waiting for."},
    task_not_dependable: {422, "A summary node cannot take part in a dependency."},
    # Breaking a document down. The first three are the document being in no
    # state to be broken down, or nobody having said who would do it; the
    # fourth is somebody having clicked twice.
    document_not_formal: {422, "The document has to be adopted, and not already used, for this."},
    decomposition_exists:
      {422, "The document already has a breakdown. Archive it to make another."},
    no_decomposition_actor:
      {422,
       "No actor holds the decomposition role. Set one with `PUT /settings/decomposition_actor`."},
    decomposition_in_flight: {409, "The document is already being broken down."},
    no_estimation_actor:
      {422, "No actor holds the estimation role. Set one with `PUT /settings/estimation_actor`."},
    nothing_to_estimate: {422, "There is nothing left to estimate on this task."},
    # Asking the AI to answer one annotation. The only condition of asking, so
    # the only thing that can be refused before the model call is queued.
    no_annotation_actor:
      {422, "No actor holds the annotation role. Set one with `PUT /settings/annotation_actor`."},
    # Filing one as a work breakdown. Both mean the document is not the shape a
    # breakdown is, which is a thing to fix in the document.
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
    # Searching without the service that does the searching. Told apart from
    # `ai_unavailable` for the same reason `token_not_configured` is told apart
    # from `unauthorized`: this one is an installation nobody finished
    # configuring, and no amount of retrying will change it.
    ai_not_configured:
      {503, "The server was started without RINTO_AI_TOKEN, so it cannot search."},
    ai_unavailable: {503, "The inference service could not be reached."},
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
