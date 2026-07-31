defmodule RintoPMO.Documents.BlockOps do
  @moduledoc false

  alias RintoPMO.Documents.DocumentBlock

  @type entry :: %{
          block_id: UUIDv7.t(),
          actor_id: UUIDv7.t(),
          content: String.t()
        }

  @spec apply([DocumentBlock.t()], list()) ::
          {:ok, [entry()]} | {:error, :invalid_block_op, map()}
  def apply(blocks, operations) when is_list(operations) do
    entries =
      Enum.map(blocks, fn block ->
        %{block_id: block.block_id, actor_id: block.actor_id, content: block.content}
      end)

    operations
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, entries}, fn {operation, index}, {:ok, current} ->
      case apply_operation(current, operation) do
        {:ok, updated} -> {:cont, {:ok, updated}}
        {:error, reason} -> {:halt, invalid(index, reason)}
      end
    end)
  end

  def apply(_blocks, _operations), do: invalid(nil, "block_ops must be an array")

  defp apply_operation(entries, operation) when is_map(operation) do
    with {:ok, name} <- fetch(operation, :op) do
      dispatch(entries, name, operation)
    end
  end

  defp apply_operation(_entries, _operation), do: {:error, "operation must be an object"}

  defp dispatch(entries, "insert_after", operation), do: insert_after(entries, operation)
  defp dispatch(entries, :insert_after, operation), do: insert_after(entries, operation)
  defp dispatch(entries, "update", operation), do: update(entries, operation)
  defp dispatch(entries, :update, operation), do: update(entries, operation)
  defp dispatch(entries, "move_after", operation), do: move_after(entries, operation)
  defp dispatch(entries, :move_after, operation), do: move_after(entries, operation)
  defp dispatch(entries, "delete", operation), do: delete(entries, operation)
  defp dispatch(entries, :delete, operation), do: delete(entries, operation)

  defp dispatch(_entries, operation, _attrs),
    do: {:error, "unsupported operation: #{inspect(operation)}"}

  defp insert_after(entries, operation) do
    with {:ok, after_block_id} <- fetch(operation, :after_block_id),
         {:ok, actor_id} <- fetch(operation, :actor_id),
         {:ok, content} <- fetch(operation, :content),
         {:ok, position} <- insertion_position(entries, after_block_id) do
      entry = %{block_id: UUIDv7.generate(), actor_id: actor_id, content: content}
      {:ok, List.insert_at(entries, position, entry)}
    end
  end

  defp update(entries, operation) do
    with {:ok, block_id} <- fetch(operation, :block_id),
         {:ok, actor_id} <- fetch(operation, :actor_id),
         {:ok, content} <- fetch(operation, :content),
         {:ok, position} <- block_position(entries, block_id) do
      entry = %{block_id: block_id, actor_id: actor_id, content: content}
      {:ok, List.replace_at(entries, position, entry)}
    end
  end

  defp move_after(entries, operation) do
    with {:ok, block_id} <- fetch(operation, :block_id),
         {:ok, after_block_id} <- fetch(operation, :after_block_id),
         :ok <- ensure_different_blocks(block_id, after_block_id),
         {:ok, position} <- block_position(entries, block_id),
         {entry, remaining} <- List.pop_at(entries, position),
         {:ok, insertion_position} <- insertion_position(remaining, after_block_id) do
      {:ok, List.insert_at(remaining, insertion_position, entry)}
    end
  end

  defp delete(entries, operation) do
    with {:ok, block_id} <- fetch(operation, :block_id),
         {:ok, position} <- block_position(entries, block_id) do
      {_entry, remaining} = List.pop_at(entries, position)
      {:ok, remaining}
    end
  end

  defp insertion_position(_entries, nil), do: {:ok, 0}

  defp insertion_position(entries, after_block_id) do
    case block_position(entries, after_block_id) do
      {:ok, position} -> {:ok, position + 1}
      {:error, _reason} -> {:error, "after_block_id does not identify a current block"}
    end
  end

  defp block_position(entries, block_id) do
    case Enum.find_index(entries, &(&1.block_id == block_id)) do
      nil -> {:error, "block_id does not identify a current block"}
      position -> {:ok, position}
    end
  end

  defp ensure_different_blocks(block_id, block_id),
    do: {:error, "a block cannot be moved after itself"}

  defp ensure_different_blocks(_block_id, _after_block_id), do: :ok

  defp fetch(attrs, key) do
    case Map.fetch(attrs, key) do
      {:ok, value} -> {:ok, value}
      :error -> fetch_string_key(attrs, key)
    end
  end

  defp fetch_string_key(attrs, key) do
    case Map.fetch(attrs, Atom.to_string(key)) do
      {:ok, value} -> {:ok, value}
      :error -> {:error, "#{key} is required"}
    end
  end

  defp invalid(index, reason) do
    details = %{reason: reason}
    details = if is_nil(index), do: details, else: Map.put(details, :operation_index, index)

    {:error, :invalid_block_op, details}
  end
end
