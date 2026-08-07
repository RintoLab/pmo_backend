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
    attrs = Map.drop(params, ["document_id", "status", "decided_by_actor_id", "decided_at"])

    with {:ok, proposed} <- documents_context().propose_block(document, attrs) do
      conn
      |> put_status(:created)
      |> render(:proposed, proposed: proposed)
    end
  end

  @doc """
  Lists the blocks carrying more than one live proposal.

  A contention has a place -- it is on a block -- so the client can mark it on
  the document itself, unlike a topic, which has none.
  """
  def contentions(conn, %{"document_id" => document_id}) do
    document = get_document!(document_id)
    render(conn, :contentions, contentions: documents_context().contentions(document))
  end

  @doc """
  Reads the document as one topic sees it.
  """
  def blocks(conn, %{"document_id" => document_id, "conversation_id" => conversation_id}) do
    document = get_document!(document_id)

    with {:ok, conversation_id} <- cast_id(conversation_id, "conversation_id") do
      blocks = documents_context().blocks_for_conversation(document, conversation_id)
      render(conn, :blocks, blocks: blocks)
    end
  end

  @doc """
  Settles a contended block in favour of one proposal.

  The winner stays live: this ends the argument, it does not commit the change.
  """
  def decide(conn, %{"document_id" => document_id, "id" => id} = params) do
    context = documents_context()
    document = get_document!(document_id)
    proposal = context.get_proposal!(document, id)

    with {:ok, actor_id} <- cast_id(params["actor_id"], "actor_id"),
         {:ok, adopted} <-
           context.decide_block(document, proposal.block_id, proposal.id, actor_id) do
      render(conn, :show, proposal: adopted)
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
