defmodule RintoPMO.Agent.AIModel do
  @moduledoc """
  A model exposed by the local `pi` runtime and selectable for AI actors.
  """

  @thinking_levels [:off, :minimal, :low, :medium, :high, :xhigh, :max]

  @enforce_keys [
    :provider,
    :model,
    :context_window,
    :max_output,
    :thinking,
    :thinking_levels,
    :images
  ]
  defstruct [
    :provider,
    :model,
    :name,
    :context_window,
    :max_output,
    :thinking,
    :thinking_levels,
    :images
  ]

  @type thinking_level :: :off | :minimal | :low | :medium | :high | :xhigh | :max

  @type t :: %__MODULE__{
          provider: String.t(),
          model: String.t(),
          name: String.t() | nil,
          context_window: pos_integer(),
          max_output: pos_integer(),
          thinking: boolean(),
          thinking_levels: [thinking_level()],
          images: boolean()
        }

  @doc """
  All thinking levels known to pi, in display order.
  """
  @spec known_thinking_levels() :: [thinking_level()]
  def known_thinking_levels, do: @thinking_levels

  @doc false
  @spec new!(map()) :: t()
  def new!(attrs) when is_map(attrs) do
    struct!(__MODULE__, %{
      provider: Map.fetch!(attrs, :provider),
      model: Map.fetch!(attrs, :model),
      name: Map.get(attrs, :name),
      context_window: Map.fetch!(attrs, :context_window),
      max_output: Map.fetch!(attrs, :max_output),
      thinking: Map.fetch!(attrs, :thinking),
      thinking_levels: Map.fetch!(attrs, :thinking_levels),
      images: Map.fetch!(attrs, :images)
    })
  end

  @doc """
  Mirrors pi-ai `getSupportedThinkingLevels/1` for a model payload.
  """
  @spec thinking_levels_for(map()) :: [thinking_level()]
  def thinking_levels_for(model) when is_map(model) do
    reasoning? = truthy?(Map.get(model, "reasoning") || Map.get(model, :reasoning))

    if reasoning? do
      level_map = Map.get(model, "thinkingLevelMap") || Map.get(model, :thinkingLevelMap) || %{}

      Enum.filter(@thinking_levels, &level_supported?(&1, level_map))
    else
      [:off]
    end
  end

  defp level_supported?(level, level_map) do
    key = Atom.to_string(level)

    case Map.fetch(level_map, key) do
      {:ok, nil} ->
        false

      {:ok, _mapped} ->
        true

      :error ->
        level not in [:xhigh, :max]
    end
  end

  defp truthy?(value), do: value in [true, "true", "yes", 1]
end
