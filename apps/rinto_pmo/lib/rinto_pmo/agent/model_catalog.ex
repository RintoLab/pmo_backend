defmodule RintoPMO.Agent.ModelCatalog do
  @moduledoc """
  ETS-backed cache of AI models discovered from the local `pi` CLI.

  Loaded once at application start so actor-creation UIs can list supported
  providers and models without shelling out on every request.
  """

  use GenServer

  require Logger

  alias RintoPMO.Agent.AIModel
  alias RintoPMO.Agent.Models

  @table __MODULE__
  @models_key :models
  @status_key :status

  @type provider_group :: %{
          provider: String.t(),
          models: [AIModel.t()]
        }

  @type status ::
          {:ok, DateTime.t()}
          | {:error, term(), DateTime.t() | nil}
          | :not_loaded

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Lists cached models, ordered by provider then model id.
  """
  @spec list_models() :: [AIModel.t()]
  def list_models do
    case safe_lookup(@models_key) do
      {:ok, models} when is_list(models) -> models
      _other -> []
    end
  end

  @doc """
  Lists cached models grouped by provider for actor-creation pickers.
  """
  @spec list_providers() :: [provider_group()]
  def list_providers do
    list_models()
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
  Returns catalog load status.
  """
  @spec status() :: status()
  def status do
    case safe_lookup(@status_key) do
      {:ok, status} -> status
      :miss -> :not_loaded
    end
  end

  @doc """
  Reloads the catalog from `pi` (or the configured loader).
  """
  @spec refresh() :: :ok | {:error, term()}
  def refresh do
    GenServer.call(__MODULE__, :refresh, 30_000)
  end

  @doc """
  Replaces the catalog contents. Intended for tests.
  """
  @spec replace!([AIModel.t()]) :: :ok
  def replace!(models) when is_list(models) do
    GenServer.call(__MODULE__, {:replace, models})
  end

  @impl true
  def init(opts) do
    table =
      case :ets.whereis(@table) do
        :undefined ->
          :ets.new(@table, [
            :named_table,
            :set,
            :public,
            read_concurrency: true
          ])

        _existing ->
          @table
      end

    :ets.insert(table, {@status_key, :not_loaded})
    :ets.insert(table, {@models_key, []})

    loader = Keyword.get_lazy(opts, :loader, &loader_config/0)

    case load_models(loader) do
      {:ok, models} ->
        store_success(models)
        {:ok, %{loader: loader}}

      {:error, reason} ->
        store_error(reason)
        Logger.warning("AI model catalog failed to load: #{inspect(reason)}")
        {:ok, %{loader: loader}}
    end
  end

  @impl true
  def handle_call(:refresh, _from, %{loader: loader} = state) do
    reply =
      case load_models(loader) do
        {:ok, models} ->
          store_success(models)
          :ok

        {:error, reason} ->
          store_error(reason)
          {:error, reason}
      end

    {:reply, reply, state}
  end

  def handle_call({:replace, models}, _from, state) do
    store_success(models)
    {:reply, :ok, state}
  end

  defp loader_config do
    conf = Application.get_env(:rinto_pmo, __MODULE__, [])
    Keyword.get(conf, :loader, :pi)
  end

  defp load_models(:pi), do: Models.list_models()
  defp load_models(:noop), do: {:ok, []}
  defp load_models({:fixed, models}) when is_list(models), do: {:ok, models}

  defp load_models(fun) when is_function(fun, 0) do
    case fun.() do
      {:ok, models} when is_list(models) -> {:ok, models}
      {:error, _} = error -> error
      other -> {:error, {:invalid_loader_result, other}}
    end
  end

  defp store_success(models) do
    sorted =
      models
      |> Enum.sort_by(&{&1.provider, &1.model})

    now = DateTime.utc_now(:microsecond)
    :ets.insert(@table, {@models_key, sorted})
    :ets.insert(@table, {@status_key, {:ok, now}})
    :ok
  end

  defp store_error(reason) do
    now = DateTime.utc_now(:microsecond)
    :ets.insert(@table, {@status_key, {:error, reason, now}})
    :ok
  end

  defp safe_lookup(key) do
    case :ets.lookup(@table, key) do
      [{^key, value}] -> {:ok, value}
      [] -> :miss
    end
  rescue
    ArgumentError -> :miss
  end
end
