defmodule RintoPMO.Agent.PiSession.Supervisor do
  @moduledoc """
  Supervises `RintoPMO.Agent.PiSession` processes.

  Sessions are started on demand and never restarted: pi holds the conversation
  -- and any parked question -- in the OS process, so a restarted session would
  come back empty and the caller would be none the wiser.
  """

  use Supervisor

  alias RintoPMO.Agent.PiSession

  @registry PiSession.Registry
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

    # :rest_for_one, as in RintoPMO.OSProcess.Supervisor: a registry restart
    # would otherwise leave sessions running under names nothing can resolve.
    Supervisor.init(children, strategy: :rest_for_one)
  end

  @doc """
  Starts a session under supervision.
  """
  @spec start_session([PiSession.start_opt()]) :: {:ok, pid()} | {:error, term()}
  def start_session(opts \\ []) do
    DynamicSupervisor.start_child(@dynamic_supervisor, {PiSession, opts})
  end

  @doc """
  Lists the ids of all running sessions.
  """
  @spec list() :: [PiSession.id()]
  def list do
    Registry.select(@registry, [{{:"$1", :_, :_}, [], [:"$1"]}])
  end

  @doc """
  Counts running sessions.
  """
  @spec count() :: non_neg_integer()
  def count, do: Registry.count(@registry)

  @doc """
  Snapshots every running session, most idle first.

  Sessions that end while this is gathering are dropped rather than reported as
  errors -- a listing is a point-in-time view, not a transaction.
  """
  @spec list_info() :: [PiSession.info()]
  def list_info do
    list()
    |> Task.async_stream(&PiSession.info/1, timeout: 5_000, on_timeout: :kill_task)
    |> Enum.flat_map(fn
      {:ok, {:ok, info}} -> [info]
      _dead_or_slow -> []
    end)
    |> Enum.sort_by(& &1.idle_ms, :desc)
  end

  @doc """
  Snapshots only the sessions blocked on a human.

  Nothing expires a question, so this is the list of conversations that will sit
  there until somebody answers -- the one to surface operationally.
  """
  @spec awaiting_input() :: [PiSession.info()]
  def awaiting_input, do: Enum.filter(list_info(), & &1.awaiting_input?)

  @doc """
  Stops every running session and returns how many were stopped.

  For shutdown and maintenance. Sessions are independent, so they are stopped
  concurrently.
  """
  @spec close_all() :: non_neg_integer()
  def close_all do
    list()
    |> Task.async_stream(&PiSession.close/1, timeout: 20_000, on_timeout: :kill_task)
    |> Enum.count(&match?({:ok, :ok}, &1))
  end
end
