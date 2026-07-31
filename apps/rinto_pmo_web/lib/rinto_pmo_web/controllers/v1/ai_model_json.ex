defmodule RintoPMOWeb.V1.AIModelJSON do
  alias RintoPMO.Agent.AIModel

  def index(%{providers: providers}) do
    %{data: Enum.map(providers, &provider_data/1)}
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
      context_window: model.context_window,
      max_output: model.max_output,
      thinking: model.thinking,
      images: model.images
    }
  end
end
