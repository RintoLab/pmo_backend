defmodule RintoPMOWeb.V1.BlockProposalController do
  @moduledoc """
  Proposed changes to a document, and what a person does with them.

  AI writes through here rather than through `POST /revisions`: a revision is
  what a human agreed to, so an agent's change has to stop at a proposal until
  somebody publishes it.

  ## Four verbs, and they are not the same verb

  `stage` saves a checkbox. `adopt` settles which of several competing
  candidates a person wants. `reject` says no. `POST /commit` publishes exactly
  what it was given. They were one action once -- deciding both ended an
  argument and marked the loser rejected -- and pulling them apart is the point
  of this API: ticking a box is not a decision, choosing between two versions is
  not publishing, and saying no is a thing a person means rather than something
  that happens to a proposal as a side effect.
  """

  use RintoPMOWeb, :controller

  alias RintoPMO.Documents.BlockProposal
  alias RintoPMO.Utils
  alias RintoPMOWeb.Plugs.ActorToken

  @statuses Map.new(BlockProposal.statuses(), &{Atom.to_string(&1), &1})

  def index(conn, %{"document_id" => document_id} = params) do
    document = get_document!(document_id)

    with {:ok, filter} <- proposal_filter(params),
         {:ok, review} <- documents_context().review_proposals(document, filter) do
      render(conn, :index, review: review)
    end
  end

  def show(conn, %{"document_id" => document_id, "id" => id}) do
    document = get_document!(document_id)

    with {:ok, id} <- cast_id(id, "id"),
         {:ok, review} <- documents_context().review_proposals(document, %{id: id}) do
      case review.proposals do
        [detail] -> render(conn, :show, detail: detail)
        [] -> {:error, :not_found}
      end
    end
  end

  @doc """
  Compiles what a topic read and rewrote into the separate changes it is made of.

  `input.kind` says what was written, not what is stored. `document` is
  whole-body Markdown and is the ordinary case; it comes back as several
  proposals -- an update here, an insertion there -- because that is what it
  actually is, and because a person will want to take some of them and not
  others. There is no proposal representing "the rewrite".

  `input.base_revision_id` is the revision the topic actually read. It is
  required and it is never filled in here: a server stamping the latest revision
  onto a body written against an older one would turn a stale rewrite into a
  silent revert of everything that landed in between.
  """
  def create(conn, %{"document_id" => document_id} = params) do
    document = get_document!(document_id)

    with {:ok, input} <- proposal_input(params),
         {:ok, proposed} <- propose(document, input) do
      conn
      |> put_status(:created)
      |> render(:proposed, proposed: proposed)
    end
  end

  # Who a proposal is by is derived from the topic, never asserted: see
  # `RintoPMO.Documents`. `status`, `staged` and the decision fields are state
  # this endpoint does not write, and an id is not something a caller chooses.
  defp proposal_input(%{"input" => input} = params) when is_map(input) do
    attrs = %{
      "conversation_id" => Map.get(params, "conversation_id"),
      "change_summary" => Map.get(params, "change_summary"),
      "content" => Map.get(input, "content"),
      "base_revision_id" => Map.get(input, "base_revision_id"),
      "block_id" => Map.get(input, "block_id")
    }

    case Map.get(input, "kind") do
      kind when kind in ["document", "block", "title"] -> {:ok, {kind, attrs}}
      other -> {:error, :invalid_input_kind, %{kind: other, allowed: ~w(document block title)}}
    end
  end

  defp proposal_input(_params),
    do: {:error, :validation_error, %{"input" => ["is required"]}}

  defp propose(document, {"document", attrs}),
    do: documents_context().propose_document(document, Map.delete(attrs, "block_id"))

  defp propose(document, {"title", attrs}),
    do: documents_context().propose_title(document, Map.delete(attrs, "block_id"))

  defp propose(document, {"block", attrs}),
    do: documents_context().propose_block(document, attrs)

  @doc """
  Saves the checkbox, and only the checkbox.

  `{"staged": true}` or `{"staged": false}` -- what the caller says is what is
  stored. Not a toggle: two saves of the same value leave the same state, which
  is what makes a retry harmless. There is no sequence number and no ordering
  protocol; a later save wins, because that is what saving a checkbox means.

  It does not settle an argument and it does not decide what a publish contains.
  Publishing names its proposals outright, so a tick that never reached the
  server costs a person a tick and never a wrong revision.
  """
  def update(conn, %{"document_id" => document_id, "id" => id} = params) do
    document = get_document!(document_id)

    with {:ok, staged} <- staged_flag(params),
         {:ok, detail} <- documents_context().stage_proposal(document, id, staged) do
      render(conn, :show, detail: detail)
    end
  end

  defp staged_flag(%{"staged" => staged}) when is_boolean(staged), do: {:ok, staged}

  defp staged_flag(_params),
    do: {:error, :validation_error, %{"staged" => ["must be true or false"]}}

  @doc """
  Chooses this candidate over the ones competing with it.

  `base_revision_id` is what the person was looking at when they chose. It is
  stored with the choice, which is what lets a later read tell a decision that
  still refers to something from one made about words that have since changed.

  The candidates it beats stay live and merely lose their tick: nothing about
  them has been decided, and un-adopting this one puts all of them back in play.
  Refused while another conflicting candidate is adopted -- switching is
  `unadopt` and then `adopt`, said out loud.

  Who chose is the token holder and cannot be sent. Choosing is the one thing in
  this system only a person does, and a body able to name somebody else would
  let an agent record a person as having agreed to its own change.
  """
  def adopt(conn, %{"document_id" => document_id, "id" => id} = params) do
    document = get_document!(document_id)
    actor_id = ActorToken.current_actor!(conn).id

    with {:ok, base_revision_id} <-
           cast_id(Map.get(params, "base_revision_id"), "base_revision_id"),
         {:ok, detail} <-
           documents_context().adopt_proposal(document, id, base_revision_id, actor_id) do
      render(conn, :show, detail: detail)
    end
  end

  @doc """
  Takes back a choice.

  Clears this proposal's adoption and does no more. It restores nothing: not a
  rejection somebody meant, not the ticks the losing candidates had before, and
  not a published revision -- publishing is the point of no return, and the way
  back from it is a new proposal.
  """
  def unadopt(conn, %{"document_id" => document_id, "id" => id}) do
    document = get_document!(document_id)

    with {:ok, detail} <- documents_context().unadopt_proposal(document, id) do
      render(conn, :show, detail: detail)
    end
  end

  @doc """
  Says no to a proposal.

  The one way to turn something down: there is no withdraw, no delete and no
  undo beside it. The row stays, with its text, its optional `reason` and every
  message that ever cited it -- "why was this not taken" is the most valuable
  thing this system records.
  """
  def reject(conn, %{"document_id" => document_id, "id" => id} = params) do
    document = get_document!(document_id)
    actor_id = ActorToken.current_actor!(conn).id
    reason = Map.get(params, "reason")

    with {:ok, detail} <- documents_context().reject_proposal(document, id, actor_id, reason) do
      render(conn, :show, detail: detail)
    end
  end

  @doc """
  Lists the pairs of live proposals that cannot both stand.

  Pairs, not groups. Two rewrites of a paragraph are alternatives and so are a
  rewrite and a deletion of it, but a rewrite and a move of that paragraph are
  not -- and a group holding all three would ask somebody to give up an edit in
  order to keep a reordering.
  """
  def contentions(conn, %{"document_id" => document_id}) do
    document = get_document!(document_id)

    render(conn, :contentions, contentions: documents_context().contentions(document))
  end

  @doc """
  Reads the document as one topic sees it.
  """
  def blocks(conn, %{"document_id" => document_id, "conversation_id" => conversation_id}) do
    context = documents_context()
    document = get_document!(document_id)

    with {:ok, conversation_id} <- cast_id(conversation_id, "conversation_id"),
         {:ok, view} <- context.conversation_document_view(document, conversation_id) do
      render(conn, :blocks, view)
    end
  end

  defp proposal_filter(params) do
    with {:ok, filter} <- status_filter(params, %{}),
         {:ok, filter} <- id_filter(params, filter, "block_id", :block_id) do
      id_filter(params, filter, "conversation_id", :conversation_id)
    end
  end

  defp status_filter(params, filter) do
    case Map.get(params, "status") do
      nil ->
        {:ok, filter}

      value ->
        case Map.fetch(@statuses, value) do
          {:ok, status} -> {:ok, Map.put(filter, :status, status)}
          :error -> {:error, :bad_request, %{"status" => ["is invalid"]}}
        end
    end
  end

  defp id_filter(params, filter, key, field) do
    case Map.get(params, key) do
      nil ->
        {:ok, filter}

      value ->
        case UUIDv7.cast(value) do
          {:ok, id} -> {:ok, Map.put(filter, field, id)}
          :error -> {:error, :bad_request, %{key => ["is invalid"]}}
        end
    end
  end

  defp cast_id(value, key) do
    case UUIDv7.cast(value || "") do
      {:ok, id} -> {:ok, id}
      :error -> {:error, :bad_request, %{key => ["is invalid"]}}
    end
  end

  defp get_document!(document_id), do: documents_context().get_document!(document_id)

  defp documents_context, do: Utils.module(:documents)
end
