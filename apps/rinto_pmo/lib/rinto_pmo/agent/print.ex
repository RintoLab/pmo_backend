defmodule RintoPMO.Agent.Print do
  @moduledoc false

  # One short-lived `pi --print --mode json` process. Shared by the one-shot
  # estimators so the event-stream loop is not copied per prompt.
  #
  # Why this shape -- json mode, idle clock rather than a wall-clock budget,
  # failure carried back rather than logged -- is written down on
  # `RintoPMO.Agent.WbsGenerator`. This module does the same thing for a
  # different question, and does not re-argue it.

  alias RintoPMO.Agent.Events
  alias RintoPMO.Agent.PiInstallation
  alias RintoPMO.OSProcess

  require Logger

  @type error ::
          :pi_not_found
          | :stalled
          | :empty_output
          | {:pi_exit, non_neg_integer(), String.t()}
          | {:provider_refused, String.t()}
          | {:spawn_failed, term()}

  @type opt ::
          {:provider, String.t() | nil}
          | {:model, String.t() | nil}
          | {:thinking, String.t() | nil}
          | {:idle_timeout, timeout()}
          | {:on_chunk, (String.t() -> any())}
          | {:name, String.t()}

  @spec run(String.t(), String.t(), [opt()]) :: {:ok, String.t()} | {:error, error()}
  def run(system_prompt, user_message, opts \\ [])
      when is_binary(system_prompt) and is_binary(user_message) do
    name = Keyword.get(opts, :name, "print")

    session_dir =
      Path.join(
        System.tmp_dir!(),
        "rinto-pmo-pi-#{name}-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(session_dir)

    try do
      call(system_prompt, user_message, session_dir, opts, name)
    after
      File.rm_rf(session_dir)
    end
  end

  # Every prompt here that asks for structured output asks for the same
  # structure -- a JSON array of objects -- so the unwrapping lives once. Two
  # copies of this would be two sets of rules about what counts as an answer,
  # and they would drift the first time one of them learned about a new way a
  # model wraps its output.
  @spec decode_objects(String.t()) :: {:ok, [map()]} | {:error, :invalid_output}
  def decode_objects(text) when is_binary(text) do
    with {:ok, json} <- extract_json(text),
         {:ok, decoded} <- JSON.decode(json),
         true <- array_of_objects?(decoded) do
      {:ok, Enum.map(decoded, &stringify_keys/1)}
    else
      _invalid -> {:error, :invalid_output}
    end
  end

  # Models wrap arrays in fences or a sentence even when asked not to. The
  # brackets are ASCII, so byte positions are the right cursor: finding the
  # first `[` and the last `]` is enough, and anything that is not an array
  # of objects is refused after decode rather than guessed at here.
  defp extract_json(text) do
    with {start, 1} <- :binary.match(text, "["),
         {from_end, 1} <- :binary.match(String.reverse(text), "]") do
      stop = byte_size(text) - from_end - 1

      if stop > start do
        {:ok, binary_part(text, start, stop - start + 1)}
      else
        :error
      end
    else
      :nomatch -> :error
    end
  end

  defp array_of_objects?(decoded) when is_list(decoded), do: Enum.all?(decoded, &is_map/1)
  defp array_of_objects?(_decoded), do: false

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {to_string(key), value} end)
  end

  defp call(system_prompt, user_message, session_dir, opts, name) do
    id = "rinto-pmo-#{name}-#{System.unique_integer([:positive, :monotonic])}"

    args =
      [
        "--print",
        "--mode",
        "json",
        "--no-session",
        "--no-tools",
        "--session-dir",
        session_dir,
        "--system-prompt",
        system_prompt
      ] ++ model_args(opts) ++ [user_message]

    start_opts = [
      id: id,
      cmd: executable(),
      args: args,
      env: PiInstallation.environment(),
      owner: self(),
      framing: :lines
    ]

    case OSProcess.start(start_opts) do
      {:ok, _pid} ->
        _ = OSProcess.close_stdin(id)
        collect(id, idle_timeout(opts), on_chunk(opts), %{deltas: [], answer: nil, stderr: []})

      {:error, {:executable_not_found, _cmd}} ->
        {:error, :pi_not_found}

      {:error, reason} ->
        {:error, {:spawn_failed, reason}}
    end
  end

  defp collect(id, idle, on_chunk, acc) do
    receive do
      {:os_process, ^id, {:stdout, line}} ->
        collect(id, idle, on_chunk, read(line, on_chunk, acc))

      {:os_process, ^id, {:stderr, data}} ->
        collect(id, idle, on_chunk, %{acc | stderr: [data | acc.stderr]})

      {:os_process, ^id, {:exit, status}} ->
        finish(status, acc)
    after
      idle -> give_up(id)
    end
  end

  defp read(line, on_chunk, acc) do
    case JSON.decode(line) do
      {:ok, frame} -> read_frame(frame, on_chunk, acc)
      _unreadable -> acc
    end
  end

  defp read_frame(frame, on_chunk, acc) do
    case Events.delta(frame) do
      {:text, delta} ->
        on_chunk.(delta)
        %{acc | deltas: [delta | acc.deltas]}

      {:thinking, _delta} ->
        acc

      nil ->
        %{acc | answer: Events.finished_message(frame) || acc.answer}
    end
  end

  defp give_up(id) do
    _ = OSProcess.stop(id)
    _ = drain(id)
    {:error, :stalled}
  end

  defp drain(id) do
    receive do
      {:os_process, ^id, {:exit, _status}} -> :ok
      {:os_process, ^id, _event} -> drain(id)
    after
      100 -> :ok
    end
  end

  defp finish({:exit, 0}, acc) do
    case refusal(acc.answer) do
      nil ->
        case answer(acc) do
          "" -> {:error, :empty_output}
          text -> {:ok, text}
        end

      complaint ->
        Logger.warning("direct prompt: the provider refused: #{complaint}")
        {:error, {:provider_refused, complaint |> message_of() |> truncate()}}
    end
  end

  defp finish({:exit, code}, acc) do
    complaint = acc.stderr |> Enum.reverse() |> IO.iodata_to_binary() |> String.trim()
    Logger.warning("direct prompt: pi exited #{code}: #{complaint}")
    {:error, {:pi_exit, code, complaint |> message_of() |> truncate()}}
  end

  defp finish(status, _acc), do: {:error, {:spawn_failed, status}}

  defp answer(%{answer: %{} = message, deltas: deltas}) do
    case Events.text_of(message) do
      "" -> streamed(deltas)
      text -> String.trim(text)
    end
  end

  defp answer(%{deltas: deltas}), do: streamed(deltas)

  defp streamed(deltas), do: deltas |> Enum.reverse() |> IO.iodata_to_binary() |> String.trim()

  defp refusal(nil), do: nil
  defp refusal(message), do: Events.refusal(message)

  defp message_of(complaint) do
    with [json] <- Regex.run(~r/\{.*\}/s, complaint),
         {:ok, %{"message" => message}} when is_binary(message) <- JSON.decode(json) do
      message
    else
      _not_a_message_we_recognise -> complaint
    end
  end

  @complaint_limit 2_000

  defp truncate(complaint) when byte_size(complaint) <= @complaint_limit, do: complaint

  defp truncate(complaint) do
    String.slice(complaint, 0, @complaint_limit) <> "… (truncated; the whole of it is in the log)"
  end

  defp on_chunk(opts) do
    case Keyword.get(opts, :on_chunk) do
      callback when is_function(callback, 1) -> callback
      _absent -> fn _chunk -> :ok end
    end
  end

  defp model_args(opts) do
    provider = Keyword.get(opts, :provider)
    model = Keyword.get(opts, :model)

    cond do
      is_binary(provider) and is_binary(model) ->
        ["--provider", provider, "--model", model] ++ thinking_args(opts)

      is_binary(model) ->
        ["--model", model] ++ thinking_args(opts)

      true ->
        []
    end
  end

  defp thinking_args(opts) do
    case Keyword.get(opts, :thinking) do
      level when is_binary(level) -> ["--thinking", level]
      _absent -> []
    end
  end

  defp idle_timeout(opts) do
    Keyword.get(opts, :idle_timeout) || 180_000
  end

  defp executable, do: Application.get_env(:rinto_pmo, :pi_executable, "pi")
end
