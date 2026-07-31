defmodule RintoPMO.Agent.Models do
  @moduledoc """
  Discovers models available to the local `pi` CLI.

  Runs `pi --list-models` and parses its fixed-width table into `AIModel` structs.
  """

  alias RintoPMO.Agent.AIModel

  @type list_opts :: [
          search: String.t(),
          executable: String.t()
        ]

  @header_columns ["provider", "model", "context", "max-out", "thinking", "images"]

  @doc """
  Column headers emitted by `pi --list-models`. Used as the stable contract for parsing.
  """
  @spec header_columns() :: [String.t()]
  def header_columns, do: @header_columns

  @doc """
  Lists models currently available to `pi` on this machine.

  Options:

    * `:search` – optional fuzzy filter forwarded to `pi --list-models <pattern>`
    * `:executable` – path or name of the `pi` binary (default: configured `:pi_executable`)
  """
  @spec list_models(list_opts()) ::
          {:ok, [AIModel.t()]}
          | {:error,
             :pi_not_found | {:pi_exit, non_neg_integer(), String.t()} | :unrecognized_output}
  def list_models(opts \\ []) do
    executable = Keyword.get_lazy(opts, :executable, &pi_executable/0)
    search = Keyword.get(opts, :search)

    with {:ok, path} <- find_executable(executable),
         {:ok, stdout} <- run_list_models(path, search) do
      parse_output(stdout)
    end
  end

  @doc """
  Parses the tabular stdout of `pi --list-models` into `AIModel` structs.
  """
  @spec parse_output(String.t()) ::
          {:ok, [AIModel.t()]} | {:error, :unrecognized_output}
  def parse_output(output) when is_binary(output) do
    lines =
      output
      |> strip_ansi()
      |> String.split("\n", trim: true)
      |> Enum.map(&String.trim_trailing/1)
      |> Enum.reject(&(&1 == ""))

    if models_unavailable?(lines) do
      {:ok, []}
    else
      case Enum.split_while(lines, &(!header_line?(&1))) do
        {_skipped, [_header | rows]} ->
          parse_rows(rows)

        _other ->
          {:error, :unrecognized_output}
      end
    end
  end

  defp pi_executable do
    Application.get_env(:rinto_pmo, :pi_executable, "pi")
  end

  defp find_executable(executable) do
    cond do
      File.regular?(executable) ->
        {:ok, executable}

      path = System.find_executable(executable) ->
        {:ok, path}

      true ->
        {:error, :pi_not_found}
    end
  end

  defp run_list_models(path, search) do
    args =
      case search do
        pattern when is_binary(pattern) and pattern != "" -> ["--list-models", pattern]
        _other -> ["--list-models"]
      end

    case System.cmd(path, args, stderr_to_stdout: false) do
      {stdout, 0} -> {:ok, stdout}
      {stdout, status} -> {:error, {:pi_exit, status, stdout}}
    end
  end

  defp models_unavailable?(lines) do
    Enum.any?(lines, fn line ->
      String.starts_with?(line, "No models available") or
        String.starts_with?(line, "No models matching")
    end)
  end

  defp header_line?(line) do
    split_columns(line) == @header_columns
  end

  defp parse_rows(rows) do
    rows
    |> Enum.reduce_while({:ok, []}, fn row, {:ok, acc} ->
      case parse_row(row) do
        {:ok, model} -> {:cont, {:ok, [model | acc]}}
        :skip -> {:cont, {:ok, acc}}
        :error -> {:halt, {:error, :unrecognized_output}}
      end
    end)
    |> case do
      {:ok, models} -> {:ok, Enum.reverse(models)}
      {:error, _} = error -> error
    end
  end

  defp parse_row(line) do
    case split_columns(line) do
      [provider, model, context, max_out, thinking, images] ->
        with {:ok, context_window} <- parse_token_count(context),
             {:ok, max_output} <- parse_token_count(max_out),
             {:ok, thinking?} <- parse_yes_no(thinking),
             {:ok, images?} <- parse_yes_no(images) do
          {:ok,
           AIModel.new!(%{
             provider: provider,
             model: model,
             context_window: context_window,
             max_output: max_output,
             thinking: thinking?,
             images: images?
           })}
        else
          :error -> :error
        end

      _other ->
        if String.contains?(line, "  "), do: :error, else: :skip
    end
  end

  defp split_columns(line), do: String.split(line, ~r/\s{2,}/, trim: true)

  defp parse_yes_no("yes"), do: {:ok, true}
  defp parse_yes_no("no"), do: {:ok, false}
  defp parse_yes_no(_other), do: :error

  defp parse_token_count(value) do
    case Regex.run(~r/^(\d+(?:\.\d+)?)([KMkm])?$/, value) do
      [_, number, ""] ->
        parse_plain_number(number)

      [_, number, unit] ->
        with {:ok, amount} <- parse_plain_number(number) do
          {:ok, scale_token_count(amount, unit)}
        end

      [_, number] ->
        parse_plain_number(number)

      nil ->
        :error
    end
  end

  defp parse_plain_number(number) do
    case Integer.parse(number) do
      {int, ""} ->
        {:ok, int}

      _ ->
        case Float.parse(number) do
          {float, ""} -> {:ok, float}
          _ -> :error
        end
    end
  end

  defp scale_token_count(number, unit) do
    multiplier =
      case unit do
        "K" -> 1_000
        "k" -> 1_000
        "M" -> 1_000_000
        "m" -> 1_000_000
      end

    round(number * multiplier)
  end

  defp strip_ansi(text) do
    Regex.replace(~r/\e\[[0-9;]*[a-zA-Z]/, text, "")
  end
end
