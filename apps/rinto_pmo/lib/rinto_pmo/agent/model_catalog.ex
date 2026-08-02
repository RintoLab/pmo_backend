defmodule RintoPMO.Agent.ModelCatalog do
  @moduledoc """
  ETS-backed cache of AI models discovered from the local `pi` RPC runtime.

  Discovery spawns a pi process and waits on an RPC round trip -- roughly a
  second -- which is far too slow to repeat per request. It runs once after
  startup and the result is served from ETS.

  Reads go straight to the table rather than through this process, so listing
  models never queues behind a refresh.

  Discovery never blocks a caller. It runs in a task, so neither application
  boot nor `refresh/1` waits for pi. What a caller gets instead is `status/1`,
  which says whether the current contents are loaded, stale, or absent -- an
  empty list on its own cannot distinguish "still loading" from "pi is missing".

  ## Options

    * `:name` - registered name, also the ETS table name. Defaults to this
      module, which is the instance the application starts.
    * `:discover` - zero-arity function returning `{:ok, models}` or
      `{:error, reason}`, defaulting to `RintoPMO.Agent.Models.list_models/0`.
      Held in state and used by both the boot-time load and every refresh.
    * `:load_on_start` - whether to discover once at startup, default `true`.

  Naming an instance lets a caller run its own catalog rather than share the
  application's. Combined with `:discover`, that is what makes the behaviour
  here testable -- deciding what a run returns, and when it finishes -- without
  a pi anywhere near it.
  """

  use GenServer

  require Logger

  alias RintoPMO.Agent.AIModel
  alias RintoPMO.Agent.Models

  @models_key :models
  @outcome_key :outcome
  @loading_key :loading

  @type provider_group :: %{
          provider: String.t(),
          models: [AIModel.t()]
        }

  @typedoc "A running catalog, by registered name."
  @type catalog :: atom()

  @typedoc """
  How the catalog finds models. Runs in a task, off the catalog process.
  """
  @type discovery :: (-> {:ok, [AIModel.t()]} | {:error, term()})

  @typedoc """
  What the last discovery attempt produced.

  `:not_loaded` means none has finished yet -- either the first one is still
  running or boot-time loading is switched off.
  """
  @type outcome ::
          :not_loaded
          | {:ok, DateTime.t()}
          | {:error, term(), DateTime.t()}

  @typedoc """
  A snapshot of the catalog's state, meant to be rendered for a client.

  `state` and `loading?` are deliberately separate: a refresh does not discard
  the models it is replacing, so a catalog can be simultaneously usable
  (`state: :ok`) and busy (`loading?: true`). A client polling after `refresh/1`
  waits for `loading?` to go false, then reads `state`.
  """
  @type status :: %{
          state: :not_loaded | :ok | :error,
          loading?: boolean(),
          updated_at: DateTime.t() | nil,
          error: term() | nil
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)

    GenServer.start_link(__MODULE__, Keyword.put(opts, :name, name), name: name)
  end

  @doc """
  Lists cached models, ordered by provider then model id.
  """
  @spec list_models(catalog()) :: [AIModel.t()]
  def list_models(catalog \\ __MODULE__) do
    case safe_lookup(catalog, @models_key) do
      {:ok, models} when is_list(models) -> models
      _other -> []
    end
  end

  @doc """
  Lists cached models grouped by provider for actor-creation pickers.
  """
  @spec list_providers(catalog()) :: [provider_group()]
  def list_providers(catalog \\ __MODULE__) do
    catalog
    |> list_models()
    |> Enum.group_by(& &1.provider)
    |> Enum.map(fn {provider, models} ->
      %{
        provider: provider,
        models: Enum.sort_by(models, & &1.model)
      }
    end)
    |> Enum.sort_by(& &1.provider)
  end

  @doc """
  Returns a snapshot of the catalog's state.
  """
  @spec status(catalog()) :: status()
  def status(catalog \\ __MODULE__) do
    outcome =
      case safe_lookup(catalog, @outcome_key) do
        {:ok, outcome} -> outcome
        :miss -> :not_loaded
      end

    loading? = match?({:ok, true}, safe_lookup(catalog, @loading_key))

    case outcome do
      :not_loaded -> %{state: :not_loaded, loading?: loading?, updated_at: nil, error: nil}
      {:ok, at} -> %{state: :ok, loading?: loading?, updated_at: at, error: nil}
      {:error, reason, at} -> %{state: :error, loading?: loading?, updated_at: at, error: reason}
    end
  end

  @doc """
  Asks for a rediscovery and returns immediately.

  Discovery takes about a second, so this does not wait for it: poll `status/1`
  until `loading?` is false, then read `state`. A refresh already in flight
  absorbs the request rather than starting a second pi process, so repeated
  calls are cheap.

  The models in place stay readable throughout, and a failed refresh leaves
  them alone -- only `status/1` changes.
  """
  @spec refresh(catalog()) :: :ok
  def refresh(catalog \\ __MODULE__), do: GenServer.cast(catalog, :refresh)

  @doc """
  Replaces the catalog contents. Intended for tests.
  """
  @spec replace!([AIModel.t()], catalog()) :: :ok
  def replace!(models, catalog \\ __MODULE__) when is_list(models) do
    GenServer.call(catalog, {:replace, models})
  end

  @impl true
  def init(opts) do
    table = Keyword.get(opts, :name, __MODULE__)
    discover = Keyword.get(opts, :discover, &Models.list_models/0)

    if :ets.whereis(table) == :undefined do
      :ets.new(table, [:named_table, :set, :public, read_concurrency: true])
    end

    :ets.insert(table, {@outcome_key, :not_loaded})
    :ets.insert(table, {@models_key, []})
    :ets.insert(table, {@loading_key, false})

    state = %{table: table, discover: discover, task: nil}

    if Keyword.get(opts, :load_on_start, load_on_start?()) do
      {:ok, state, {:continue, :load}}
    else
      {:ok, state}
    end
  end

  @impl true
  def handle_continue(:load, state), do: {:noreply, start_load(state)}

  @impl true
  def handle_cast(:refresh, state), do: {:noreply, start_load(state)}

  @impl true
  def handle_call({:replace, models}, _from, state) do
    store_success(state.table, models)
    {:reply, :ok, state}
  end

  # Discovery runs in a task so this process keeps handling messages -- which is
  # what lets a second refresh be recognised as redundant instead of queueing
  # another pi process behind the first.
  #
  # Unlinked deliberately: `Task.async/1` would link, and a discovery that
  # raised -- `File.mkdir_p!` on a read-only tmp, `AIModel.new!` on a malformed
  # payload -- would take this process down with it. A deterministic failure
  # would then crash-loop it until the supervisor gave up on the application,
  # which is exactly what handling `{:error, _}` gracefully is meant to prevent.
  @impl true
  def handle_info({ref, result}, %{task: %Task{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])
    store_result(state.table, result)
    {:noreply, %{state | task: nil}}
  end

  # The task died rather than returning an error tuple.
  def handle_info({:DOWN, ref, :process, _pid, reason}, %{task: %Task{ref: ref}} = state) do
    store_result(state.table, {:error, {:discovery_crashed, reason}})
    {:noreply, %{state | task: nil}}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp start_load(%{task: nil} = state) do
    :ets.insert(state.table, {@loading_key, true})

    %{state | task: Task.Supervisor.async_nolink(RintoPMO.TaskSupervisor, state.discover)}
  end

  # Already discovering; the in-flight run will produce results just as fresh.
  defp start_load(state), do: state

  # Discovery failing must not take the application down: pi may not be
  # installed at all, and every other feature works without it. The failure is
  # recorded so `status/1` can report it rather than it reading as an empty
  # catalog. The previously loaded models are deliberately left in place.
  defp store_result(table, {:ok, models}), do: store_success(table, models)

  defp store_result(table, {:error, reason}) do
    Logger.warning("AI model catalog failed to load: #{inspect(reason)}")
    store_error(table, reason)
  end

  defp load_on_start? do
    :rinto_pmo
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:load_on_start, true)
  end

  defp store_success(table, models) do
    sorted = Enum.sort_by(models, &{&1.provider, &1.model})

    :ets.insert(table, {@models_key, sorted})
    :ets.insert(table, {@outcome_key, {:ok, DateTime.utc_now(:microsecond)}})
    :ets.insert(table, {@loading_key, false})
    :ok
  end

  # Note the absence of a models write: what is already cached stays served.
  defp store_error(table, reason) do
    :ets.insert(table, {@outcome_key, {:error, reason, DateTime.utc_now(:microsecond)}})
    :ets.insert(table, {@loading_key, false})
    :ok
  end

  defp safe_lookup(table, key) do
    case :ets.lookup(table, key) do
      [{^key, value}] -> {:ok, value}
      [] -> :miss
    end
  rescue
    ArgumentError -> :miss
  end
end
