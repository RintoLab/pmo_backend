defmodule RintoPMO.AI.Passages do
  @moduledoc false

  # UTF-8 bytes are a conservative token budget for the deployed Qwen byte
  # tokenizer. Configuration leaves room for the reranker's prompt template;
  # the complete query is charged again for every passage.
  def for_rerank(documents, query, max_input_bytes) do
    budget = max_input_bytes - byte_size(query)

    documents
    |> Enum.with_index()
    |> Enum.flat_map(fn {text, index} ->
      text
      |> split(budget)
      |> Enum.map(&%{index: index, text: &1})
    end)
  end

  # A query that leaves no room for even one UTF-8 codepoint cannot be fixed
  # by splitting documents. Let the service reject it with its actual token
  # limit, rather than truncating the caller's query or creating tiny passages.
  defp split(text, budget) when budget < 4 or byte_size(text) <= budget, do: [text]

  defp split(text, budget) do
    size = boundary(text, budget)
    <<passage::binary-size(^size), rest::binary>> = text
    [passage | split(rest, budget)]
  end

  # Move a byte boundary out of any UTF-8 continuation bytes. Splitting inside
  # a codepoint would produce invalid JSON or alter the document being scored.
  defp boundary(text, size) do
    if :binary.at(text, size) in 0x80..0xBF, do: boundary(text, size - 1), else: size
  end
end
