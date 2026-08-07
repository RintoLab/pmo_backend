defmodule RintoPMO.Documents.Session.Supervisor do
  @moduledoc """
  Supervises one `RintoPMO.Documents.Session` per document.

  Sessions are `:temporary`. Restarting one would be harmless -- it holds no
  state that is only in memory -- but it would also be pointless: whoever
  wanted the session will ask for it again, and until then a process rebuilding
  a cache nobody is reading is just cost. The proposals it caches are in the
  database either way.
  """

  use Supervisor

  alias RintoPMO.Documents.Session

  @registry Session.Registry
  @dynamic_supervisor __MODULE__.DynamicSupervisor

  @doc false
  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    children = [
      {Registry, keys: :unique, name: @registry},
      {DynamicSupervisor, name: @dynamic_supervisor, strategy: :one_for_one}
    ]

    # :rest_for_one, as elsewhere: a registry restart would leave sessions
    # running under names nothing can resolve.
    Supervisor.init(children, strategy: :rest_for_one)
  end

  @doc """
  Opens a session for a document, or returns the one already open.
  """
  @spec start_session([Session.option()]) :: {:ok, pid()} | {:error, term()}
  def start_session(opts) do
    case DynamicSupervisor.start_child(@dynamic_supervisor, {Session, opts}) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Counts open sessions.
  """
  @spec count() :: non_neg_integer()
  def count, do: Registry.count(@registry)

  @doc """
  Lists the ids of the documents with an open session.
  """
  @spec list() :: [UUIDv7.t()]
  def list do
    Registry.select(@registry, [{{:"$1", :_, :_}, [], [:"$1"]}])
  end
end
