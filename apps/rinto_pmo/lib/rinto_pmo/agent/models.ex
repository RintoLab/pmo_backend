defmodule RintoPMO.Agent.Models do
  @moduledoc """
  Discovers models available to the local `pi` runtime via RPC.

  Uses `get_available_models` so each entry includes reasoning metadata and
  `thinkingLevelMap`, which `pi --list-models` does not expose.
  """

  alias RintoPMO.Agent.AIModel
  alias RintoPMO.Agent.Rpc
  alias RintoPMO.Utils

  @type list_opts :: [
          executable: String.t(),
          timeout: timeout(),
          offline: boolean()
        ]

  @doc """
  Lists models currently available to `pi` on this machine.
  """
  @spec list_models(list_opts()) ::
          {:ok, [AIModel.t()]}
          | {:error, Rpc.error() | :unrecognized_output}
  def list_models(opts \\ []) do
    case rpc().request(%{"type" => "get_available_models"}, opts) do
      {:ok, response} -> from_rpc_response(response)
      {:error, _} = error -> error
    end
  end

  @doc """
  Converts a `get_available_models` RPC response into `AIModel` structs.
  """
  @spec from_rpc_response(map()) ::
          {:ok, [AIModel.t()]} | {:error, :unrecognized_output | {:rpc_error, String.t()}}
  def from_rpc_response(%{"success" => false, "error" => message}) when is_binary(message) do
    {:error, {:rpc_error, message}}
  end

  def from_rpc_response(%{"success" => true, "data" => %{"models" => models}})
      when is_list(models) do
    parsed =
      Enum.reduce_while(models, {:ok, []}, fn model, {:ok, acc} ->
        case from_rpc_model(model) do
          {:ok, ai_model} -> {:cont, {:ok, [ai_model | acc]}}
          :error -> {:halt, {:error, :unrecognized_output}}
        end
      end)

    case parsed do
      {:ok, list} ->
        {:ok,
         list
         |> Enum.reverse()
         |> Enum.sort_by(&{&1.provider, &1.model})}

      {:error, _} = error ->
        error
    end
  end

  def from_rpc_response(_other), do: {:error, :unrecognized_output}

  @doc false
  @spec from_rpc_model(map()) :: {:ok, AIModel.t()} | :error
  def from_rpc_model(model) when is_map(model) do
    attrs = %{
      provider: field(model, "provider", :provider),
      id: field(model, "id", :id),
      context: field(model, "contextWindow", :contextWindow),
      max_tokens: field(model, "maxTokens", :maxTokens),
      input: field(model, "input", :input) || [],
      reasoning: field(model, "reasoning", :reasoning) || false,
      name: field(model, "name", :name)
    }

    if valid_model_attrs?(attrs) do
      {:ok,
       AIModel.new!(%{
         provider: attrs.provider,
         model: attrs.id,
         name: if(is_binary(attrs.name), do: attrs.name),
         context_window: attrs.context,
         max_output: attrs.max_tokens,
         thinking: attrs.reasoning in [true, "true"],
         thinking_levels: AIModel.thinking_levels_for(model),
         images: images?(attrs.input)
       })}
    else
      :error
    end
  end

  def from_rpc_model(_other), do: :error

  defp rpc, do: Utils.module(:rpc)

  defp field(map, string_key, atom_key) do
    Map.get(map, string_key) || Map.get(map, atom_key)
  end

  defp valid_model_attrs?(%{provider: provider, id: id, context: context, max_tokens: max_tokens}) do
    is_binary(provider) and provider != "" and
      is_binary(id) and id != "" and
      is_integer(context) and context > 0 and
      is_integer(max_tokens) and max_tokens > 0
  end

  defp images?(input) when is_list(input) do
    Enum.any?(input, &(&1 in ["image", :image]))
  end

  defp images?(_other), do: false
end
