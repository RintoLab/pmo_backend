defmodule RintoPMO.Documents.Session do
  @moduledoc """
  An open editing session on one document.

  ## Per document, not per topic

  This is the opposite of `RintoPMO.Agent.PiSession`, which is one process per
  conversation. Here N topics may be editing one document at once, and they all
  go through this one process.

  Giving each topic its own working copy would produce N forked documents and a
  genuine merge problem, worse than the one it set out to avoid. Sharing one
  copy means the document never forks; disagreement is pushed down to the
  block, where two proposals on the same block are simply a question for a
  human rather than text to be merged.

  ## What it holds: nothing

  `RintoPMO.Documents.BlockProposal` rows are the truth, and this process
  deliberately caches none of them. What it provides is serialisation -- one
  document's edits go through one process, in order -- and every call reads
  current state.

  That is why proposals had to be persisted in the first place: "settle this in
  a new topic" puts two of them in front of an agent through `message_refs`,
  and a reference can only point at something with an id, not at a term inside
  a GenServer.

  A cached view was tried and removed: every `RintoPMO.Documents` function here
  re-reads the latest revision under its own lock, so the cache was never read
  and its only possible contribution was going stale. The design allows for
  caching later; if it comes back it should be measured first, and ETS is the
  likelier home. A caller reaching for `RintoPMO.Documents` directly is
  therefore not cheating -- it is only giving up the ordering.

  Callers are expected to have loaded the document already (every controller
  does, to answer 404), so a session does not re-check that it exists.
  """

  use GenServer

  alias RintoPMO.Documents
  alias RintoPMO.Documents.Document

  @registry __MODULE__.Registry

  @type option :: {:document_id, UUIDv7.t()}

  # Public API

  @doc """
  Starts a session for a document. Prefer `RintoPMO.Documents.Session.Supervisor.start_session/1`.
  """
  @spec start_link([option()]) :: GenServer.on_start()
  def start_link(opts) do
    document_id = Keyword.fetch!(opts, :document_id)
    GenServer.start_link(__MODULE__, opts, name: via(document_id))
  end

  @doc false
  def child_spec(opts) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}, restart: :temporary}
  end

  @doc """
  Records what a topic wants a block to say, replacing that topic's previous
  proposal on the block if it had one.

  Answers with the number of live proposals now on the block, so a topic
  learns straight away that it is not alone there.
  """
  @spec propose(UUIDv7.t(), UUIDv7.t(), UUIDv7.t(), UUIDv7.t(), String.t()) ::
          {:ok, Documents.Behaviour.proposed()}
          | {:error, Ecto.Changeset.t()}
          | {:error, atom(), map()}
  def propose(document_id, block_id, conversation_id, actor_id, content) do
    call(document_id, {:propose, block_id, conversation_id, actor_id, content})
  end

  @doc """
  Reads the document as one topic sees it: its own proposals standing in, and
  the count of anyone else's.
  """
  @spec get_blocks(UUIDv7.t(), UUIDv7.t()) ::
          {:ok, [Documents.Behaviour.conversation_block()]} | {:error, :not_found}
  def get_blocks(document_id, conversation_id) do
    call(document_id, {:get_blocks, conversation_id})
  end

  @doc """
  Lists the blocks carrying more than one live proposal.
  """
  @spec contentions(UUIDv7.t()) ::
          {:ok, [Documents.Behaviour.contention()]} | {:error, :not_found}
  def contentions(document_id), do: call(document_id, :contentions)

  @doc """
  Settles a contended block in favour of one proposal.
  """
  @spec decide(UUIDv7.t(), UUIDv7.t(), UUIDv7.t(), UUIDv7.t()) ::
          {:ok, Documents.BlockProposal.t()}
          | {:error, Ecto.Changeset.t()}
          | {:error, atom(), map()}
  def decide(document_id, block_id, proposal_id, actor_id) do
    call(document_id, {:decide, block_id, proposal_id, actor_id})
  end

  @doc """
  Turns the chosen proposals into a revision.

  A commit spanning several documents is several revisions -- `document_revisions`
  belongs to one document -- so the layer above calls this on each session
  inside one transaction. There is no cross-document commit record; "what did
  that discussion change?" is answered by `source_conversation_id`.
  """
  @spec commit(UUIDv7.t(), map()) ::
          {:ok, Documents.DocumentRevision.t()}
          | {:error, Ecto.Changeset.t()}
          | {:error, atom(), map()}
  def commit(document_id, attrs), do: call(document_id, {:commit, attrs})

  @doc """
  Ends the session. The proposals stay in the database.
  """
  @spec discard(UUIDv7.t()) :: :ok
  def discard(document_id) do
    case whereis(document_id) do
      {:ok, pid} -> GenServer.stop(pid, :normal, 5_000)
      :error -> :ok
    end
  catch
    :exit, _reason -> :ok
  end

  @doc """
  Returns whether a document currently has an open session.
  """
  @spec open?(UUIDv7.t()) :: boolean()
  def open?(document_id) do
    case whereis(document_id) do
      {:ok, pid} -> Process.alive?(pid)
      :error -> false
    end
  end

  # GenServer

  @impl true
  def init(opts) do
    # No database access here: it would block the supervisor starting this, and
    # there is nothing to load. Only the id is needed, since every context
    # function re-reads current state under its own lock.
    {:ok, %{document: %Document{id: Keyword.fetch!(opts, :document_id)}}}
  end

  @impl true
  def handle_call({:propose, block_id, conversation_id, actor_id, content}, _from, state) do
    result =
      Documents.propose_block(state.document, %{
        block_id: block_id,
        conversation_id: conversation_id,
        actor_id: actor_id,
        content: content
      })

    {:reply, result, state}
  end

  def handle_call({:get_blocks, conversation_id}, _from, state) do
    {:reply, {:ok, Documents.blocks_for_conversation(state.document, conversation_id)}, state}
  end

  def handle_call(:contentions, _from, state) do
    {:reply, {:ok, Documents.contentions(state.document)}, state}
  end

  def handle_call({:decide, block_id, proposal_id, actor_id}, _from, state) do
    {:reply, Documents.decide_block(state.document, block_id, proposal_id, actor_id), state}
  end

  def handle_call({:commit, attrs}, _from, state) do
    {:reply, Documents.commit_proposals(state.document, attrs), state}
  end

  # Helpers

  defp call(document_id, request) do
    case whereis(document_id) do
      {:ok, pid} -> GenServer.call(pid, request)
      :error -> {:error, :not_found}
    end
  catch
    :exit, {reason, _call} when reason in [:noproc, :normal, :shutdown] -> {:error, :not_found}
  end

  defp whereis(document_id) do
    case Registry.lookup(@registry, document_id) do
      [{pid, _value}] -> {:ok, pid}
      [] -> :error
    end
  end

  defp via(document_id), do: {:via, Registry, {@registry, document_id}}
end
