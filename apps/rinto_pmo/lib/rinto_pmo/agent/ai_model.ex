defmodule RintoPMO.Agent.AIModel do
  @moduledoc """
  A model exposed by the local `pi` CLI and selectable for AI actors.
  """

  @enforce_keys [:provider, :model, :context_window, :max_output, :thinking, :images]
  defstruct [:provider, :model, :context_window, :max_output, :thinking, :images]

  @type t :: %__MODULE__{
          provider: String.t(),
          model: String.t(),
          context_window: pos_integer(),
          max_output: pos_integer(),
          thinking: boolean(),
          images: boolean()
        }

  @doc false
  @spec new!(map()) :: t()
  def new!(attrs) when is_map(attrs) do
    struct!(__MODULE__, %{
      provider: Map.fetch!(attrs, :provider),
      model: Map.fetch!(attrs, :model),
      context_window: Map.fetch!(attrs, :context_window),
      max_output: Map.fetch!(attrs, :max_output),
      thinking: Map.fetch!(attrs, :thinking),
      images: Map.fetch!(attrs, :images)
    })
  end
end
