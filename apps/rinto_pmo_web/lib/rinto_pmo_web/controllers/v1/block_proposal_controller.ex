defmodule RintoPMOWeb.V1.BlockProposalController do
  @moduledoc """
  Proposed block changes, and the decisions taken about them.

  AI writes through here rather than through `POST /revisions`: a revision is
  what a human agreed to, so an agent's change has to stop at a proposal until
  somebody commits it.
  """

  use RintoPMOWeb, :controller

  alias RintoPMO.Documents.BlockProposal
  alias RintoPMO.Utils

  @statuses Map.new(BlockProposal.statuses(), &{Atom.to_string(&1), &1})

  def index(conn, %{"document_id" => document_id} = params) do
    document = get_document!(document_id)

    with {:ok, filter} <- proposal_filter(params) do
      proposals = documents_context().list_proposals(document, filter)
      render(conn, :index, proposals: proposals)
    end
  end

  def show(conn, %{"document_id" => document_id, "id" => id}) do
    document = get_document!(document_id)
    proposal = documents_context().get_proposal!(document, id)
    render(conn, :show, proposal: proposal)
  end

  def create(conn, %{"document_id" => document_id} = params) do
    document = get_document!(document_id)

    attrs =
      Map.drop(params, [
        "document_id",
        "status",
        "decided_by_actor_id",
        "decided_at",
        "block_ops"
      ])

    with {:ok, proposed} <- propose(document, attrs) do
      conn
      |> put_status(:created)
      |> render(:proposed, proposed: proposed)
    end
  end

  # `scope` chooses which slot the proposal claims. It defaults to `"block"`, so
  # a client that has never heard of scopes keeps working unchanged.
  #
  # `block_ops` is dropped above rather than accepted: the operation list of a
  # document proposal is compiled from its Markdown here, never sent in. A
  # caller able to hand over its own operations could write a revision that no
  # Markdown produces, which is exactly the door proposals exist to close.
  defp propose(document, %{"scope" => "title"} = attrs) do
    documents_context().propose_title(document, Map.delete(attrs, "block_id"))
  end

  # `content` is the whole body here, as Markdown, and is cut into blocks
  # server-side -- the same rule a new document's body follows.
  defp propose(document, %{"scope" => "document"} = attrs) do
    documents_context().propose_document(document, Map.delete(attrs, "block_id"))
  end

  defp propose(_document, %{"scope" => scope}) when scope not in ["block", "title", "document"] do
    {:error, :invalid_scope, %{scope: scope, allowed: ["block", "title", "document"]}}
  end

  defp propose(document, attrs), do: documents_context().propose_block(document, attrs)

  @doc """
  Lists the blocks carrying more than one live proposal.

  A contention has a place -- it is on a block -- so the client can mark it on
  the document itself, unlike a topic, which has none.
  """
  def contentions(conn, %{"document_id" => document_id}) do
    context = documents_context()
    document = get_document!(document_id)

    # Document-level arguments arrive beside the block ones rather than among
    # them: they have no block to be marked on, and no per-block decision would
    # settle them.
    render(conn, :contentions,
      contentions: context.contentions(document),
      scope_contentions: context.scope_contentions(document)
    )
  end

  @doc """
  Reads the document as one topic sees it.
  """
  def blocks(conn, %{"document_id" => document_id, "conversation_id" => conversation_id}) do
    context = documents_context()
    document = get_document!(document_id)

    with {:ok, conversation_id} <- cast_id(conversation_id, "conversation_id") do
      # A whole-document rewrite is reported alongside the blocks rather than
      # standing in for them: it is not a per-block overlay, and rendering it as
      # one would mean inventing ids for text that has none yet. A client seeing
      # one shows its diff instead of this list.
      render(conn, :blocks,
        blocks: context.blocks_for_conversation(document, conversation_id),
        document_proposal: context.document_proposal_for_conversation(document, conversation_id)
      )
    end
  end

  @doc """
  Settles a contended block in favour of one proposal.

  The winner stays live: this ends the argument, it does not commit the change.
  """
  def decide(conn, %{"document_id" => document_id, "id" => id} = params) do
    document = get_document!(document_id)
    proposal = documents_context().get_proposal!(document, id)

    with {:ok, actor_id} <- cast_id(params["actor_id"], "actor_id"),
         {:ok, adopted} <- settle(document, proposal, actor_id) do
      render(conn, :show, proposal: adopted)
    end
  end

  @doc """
  Carries a whole-document proposal across the revisions that landed under it.

  Idempotent: one already compiled against the latest revision comes back
  unchanged, so a caller may ask without first working out whether it needs to.
  """
  def rebase(conn, %{"document_id" => document_id, "id" => id}) do
    document = get_document!(document_id)

    with {:ok, rebased} <- documents_context().rebase_document_proposal(document, id) do
      render(conn, :show, proposal: rebased)
    end
  end

  # The proposal itself says which argument it is in, so a client deciding one
  # does not have to know: it names a proposal, the same way it did before
  # scopes existed.
  defp settle(document, %{scope: :title} = proposal, actor_id) do
    documents_context().decide_title(document, proposal.id, actor_id)
  end

  defp settle(document, %{scope: :document} = proposal, actor_id) do
    documents_context().decide_document(document, proposal.id, actor_id)
  end

  defp settle(document, proposal, actor_id) do
    documents_context().decide_block(document, proposal.block_id, proposal.id, actor_id)
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
