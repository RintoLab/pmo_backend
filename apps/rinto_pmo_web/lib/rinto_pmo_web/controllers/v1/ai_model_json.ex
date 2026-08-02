defmodule RintoPMOWeb.V1.AIModelJSON do
  alias RintoPMO.Agent.AIModel

  def index(%{providers: providers, status: status}) do
    %{
      data: Enum.map(providers, &provider_data/1),
      status: status_data(status)
    }
  end

  # `error` is rendered with inspect/1 rather than passed through: the reasons
  # are arbitrary Elixir terms, and this is diagnostic text for an operator, not
  # a code a client should branch on -- `state` is that.
  defp status_data(%{state: state, loading?: loading?, updated_at: updated_at, error: error}) do
    %{
      state: state,
      loading: loading?,
      updated_at: updated_at,
      error: if(error, do: inspect(error))
    }
  end

  defp provider_data(%{provider: provider, models: models}) do
    %{
      provider: provider,
      models: Enum.map(models, &model_data/1)
    }
  end

  defp model_data(%AIModel{} = model) do
    %{
      model: model.model,
      name: model.name,
      context_window: model.context_window,
      max_output: model.max_output,
      thinking: model.thinking,
      thinking_levels: model.thinking_levels,
      images: model.images
    }
  end
end
