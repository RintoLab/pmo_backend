defmodule RintoPMO.Tasks.DependencyGraph do
  @moduledoc """
  The dependency edges, in memory, so that asking "would this make a loop?"
  does not go to the database.

  ## What is cached is the edges, not a graph

  `:digraph` was the obvious thing to keep here and is deliberately not kept.
  It is an ETS-backed *mutable* structure owned by whichever process created
  it, so a cached one has to live behind its owner: either every check pays a
  GenServer round trip and they all serialise, or readers reach into another
  process's tables through its implementation rather than its interface.

  An edge set has neither problem. It is plain data in a `:bag`, readers walk
  it in their own process with no message passing, and the question that used
  to need a graph -- see below -- turns out not to need one.

  ## The question is reachability, not acyclicity

  Adding "A depends on B" closes a loop **exactly when B already depends on A**,
  directly or through any chain. So there is nothing to build and nothing to
  check for cycles: walk from A along "who depends on me" and see whether B
  turns up.

  `path/2` walks breadth-first and keeps predecessors, so a refusal still names
  the loop it would have closed rather than merely asserting one -- the one
  thing `:digraph.add_edge/3` gave for free that was worth keeping.

  ## Staleness is conservative, by construction

  This is the whole reason a cache is tolerable for a check whose wrong answer
  would be permanent. A stale cache errs in one direction only:

    * **Extra edges** -- rows deleted from the database that are still here.
      Extra edges only ever add constraints, so the worst case is refusing an
      edge that would in fact have been legal. Annoying, visible, recoverable.
    * **Missing edges** -- the dangerous kind, because a missing edge is how a
      real cycle gets through. These can only come from a write that landed in
      the database while failing to land here, so the write path updates this
      immediately after a successful insert, in the same process, and `init/1`
      rebuilds from the database on every start.

  Task deletion is the case that would otherwise be missed: `task_dependencies`
  cascades in the database, which the application never sees. `forget_task/1`
  is called from `RintoPMO.Tasks.delete_task/1` for that, and if some later
  delete path forgets to, the failure is of the harmless kind above rather than
  the permanent one.
  """

  use GenServer

  import Ecto.Query

  alias RintoPMO.Repo
  alias RintoPMO.Tasks.Dependency

  @table __MODULE__

  @doc false
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  A chain from `from` to `to` along "who depends on me", or `nil`.

  Read straight from the table in the calling process: no message is sent, so
  concurrent checks do not queue behind one another.
  """
  @spec path(UUIDv7.t(), UUIDv7.t()) :: [UUIDv7.t()] | nil
  def path(from, to) do
    walk([from], %{from => nil}, to)
  end

  @doc """
  Records an edge: `task` waits for `depends_on`.
  """
  @spec put(UUIDv7.t(), UUIDv7.t()) :: :ok
  def put(task_id, depends_on_id), do: GenServer.call(__MODULE__, {:put, task_id, depends_on_id})

  @doc """
  Forgets one edge.
  """
  @spec drop(UUIDv7.t(), UUIDv7.t()) :: :ok
  def drop(task_id, depends_on_id),
    do: GenServer.call(__MODULE__, {:drop, task_id, depends_on_id})

  @doc """
  Forgets every edge touching a task, at either end.

  For deletes, which the database cascades without telling anyone.
  """
  @spec forget_task(UUIDv7.t()) :: :ok
  def forget_task(task_id), do: GenServer.call(__MODULE__, {:forget_task, task_id})

  @doc """
  Rebuilds from the database.

  Called on start. Also what a test uses to put the table back to a known
  state, since this is process-global and outlives any one of them.
  """
  @spec reload() :: :ok
  def reload, do: GenServer.call(__MODULE__, :reload)

  @impl GenServer
  def init(_opts) do
    # `:protected` so that readers can walk it without a message, and only this
    # process can write. `:bag` because one task blocks many.
    :ets.new(@table, [:bag, :protected, :named_table, read_concurrency: true])

    {:ok, nil, {:continue, :load}}
  end

  @impl GenServer
  def handle_continue(:load, state) do
    load()

    {:noreply, state}
  end

  @impl GenServer
  def handle_call({:put, task_id, depends_on_id}, _from, state) do
    :ets.insert(@table, {depends_on_id, task_id})

    {:reply, :ok, state}
  end

  def handle_call({:drop, task_id, depends_on_id}, _from, state) do
    :ets.delete_object(@table, {depends_on_id, task_id})

    {:reply, :ok, state}
  end

  def handle_call({:forget_task, task_id}, _from, state) do
    :ets.delete(@table, task_id)
    :ets.match_delete(@table, {:_, task_id})

    {:reply, :ok, state}
  end

  def handle_call(:reload, _from, state) do
    :ets.delete_all_objects(@table)
    load()

    {:reply, :ok, state}
  end

  defp load do
    Dependency
    |> select([edge], {edge.depends_on_id, edge.task_id})
    |> Repo.all()
    |> then(&:ets.insert(@table, &1))
  rescue
    # The table starts empty rather than the application failing to boot. An
    # empty cache refuses nothing and permits everything the database would
    # have permitted a moment earlier; a node that will not start is worse.
    _error -> :ok
  end

  # Breadth-first, carrying `seen` as a predecessor map so the answer is the
  # chain rather than a yes. Terminates on `seen`, so it is safe even against a
  # table that somehow contains a cycle.
  defp walk([], _seen, _target), do: nil

  defp walk([current | queue], seen, target) do
    next =
      @table
      |> :ets.lookup(current)
      |> Enum.map(fn {_blocker, dependent} -> dependent end)
      |> Enum.reject(&Map.has_key?(seen, &1))

    if target in next do
      chain(seen, current) ++ [target]
    else
      seen = Enum.reduce(next, seen, &Map.put(&2, &1, current))
      walk(queue ++ next, seen, target)
    end
  end

  defp chain(seen, node, acc \\ []) do
    case Map.fetch!(seen, node) do
      nil -> [node | acc]
      previous -> chain(seen, previous, [node | acc])
    end
  end
end
