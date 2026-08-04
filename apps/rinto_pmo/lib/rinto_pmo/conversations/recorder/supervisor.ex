defmodule RintoPMO.Conversations.Recorder.Supervisor do
  @moduledoc """
  Supervises one `RintoPMO.Conversations.Recorder` per conversation.

  Recorders are `:temporary`, like the sessions they follow. A restarted
  recorder would have missed whatever arrived while it was down and could not
  tell, and the pi process it was listening to is usually gone anyway.
  """

  use Supervisor

  alias RintoPMO.Conversations.Recorder

  @registry Recorder.Registry
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

    # :rest_for_one, as in the pi session supervisor: a registry restart would
    # leave recorders running under names nothing can resolve.
    Supervisor.init(children, strategy: :rest_for_one)
  end

  @doc """
  Starts a recorder under supervision, or returns the one already running.
  """
  @spec start_recorder([Recorder.option()]) :: {:ok, pid()} | {:error, term()}
  def start_recorder(opts) do
    case DynamicSupervisor.start_child(@dynamic_supervisor, {Recorder, opts}) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Counts running recorders.
  """
  @spec count() :: non_neg_integer()
  def count, do: Registry.count(@registry)
end
