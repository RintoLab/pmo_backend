defmodule RintoPMO.Agent.WbsGenerator do
  @moduledoc """
  Breaks one document down into a task list, with one short-lived model call.

  Built the same way as `RintoPMO.Agent.TitleGenerator` and for the same
  reasons: its own `pi --print` process, asked once, read off stdout, let go.
  Sending this down a topic's own session would put a question nobody asked
  into the context a person is talking into, stream frames the client has to
  learn to ignore, and have `RintoPMO.Conversations.Recorder` write the answer
  down as a turn.

  Three things it does *not* share with naming, each for a reason worth knowing
  before touching them:

  ## It is given the whole document

  Naming is deliberately never given a document's contents -- a title is worth
  one small request. A breakdown is worth the large one: what the sections are
  and what they say is the entire input to deciding what the work is.

  There is no length ceiling here, and none is wanted. How long a document is
  belongs to whoever wrote it. A document too long for the model to take is a
  failure like any other and is reported as one.

  ## Its timeout is its own

  Naming's is set for a small request. Reading a document and writing a
  breakdown is not that, so this reads its own setting rather than borrowing.

  ## There is no fallback

  A topic that misses its one chance to be named can be named from its first
  message instead, so `RintoPMO.Conversations.TitleWorker` treats a model
  failure as an ordinary outcome. Nothing corresponds to that here: a
  breakdown nobody could produce is not recoverable by producing a worse one,
  and inventing a plausible tree is far worse than saying so. Every failure is
  `{:error, reason}` and every reason is passed along as it came.

  ## What comes back

  Markdown, and this module does not check its shape. What the notation means
  is settled where the task list is read, not here -- and until that exists
  there is nothing to validate against. See
  `docs/implementation-plan-task-decomposition.md`.
  """

  alias RintoPMO.OSProcess

  require Logger

  @typedoc """
  The document to break down: its title, and its blocks in order.
  """
  @type input :: %{
          required(:title) => String.t(),
          required(:blocks) => [String.t()]
        }

  @type opt ::
          {:provider, String.t() | nil}
          | {:model, String.t() | nil}
          | {:thinking, String.t() | nil}
          | {:timeout, timeout()}
          | {:on_chunk, (String.t() -> any())}

  @type error ::
          :pi_not_found
          | :timeout
          | :empty_output
          | {:pi_exit, non_neg_integer(), String.t()}
          | {:spawn_failed, term()}

  defmodule Behaviour do
    @moduledoc """
    One round trip to a model, for a breakdown and nothing else.

    Exists so that everything around the call -- eligibility, the live slot,
    who authors the result, what it is titled -- is testable without a model.
    """

    alias RintoPMO.Agent.WbsGenerator

    @callback generate(WbsGenerator.input(), [WbsGenerator.opt()]) ::
                {:ok, String.t()} | {:error, WbsGenerator.error()}
  end

  @behaviour Behaviour

  @system_prompt """
  You break a plan down into the work it implies. You are given a document as \
  JSON: a title, and its sections in order. Reply with the work breakdown as \
  Markdown.

  Shape, and follow it exactly:
  - `##` heading -- a chunk of work. Use `##` and only `##`.
  - `-` list item under a heading -- one task somebody can pick up and finish.
  - Indented `-` under a task -- a smaller task, or what "done" means for it. \
  Indent as deep as the work actually nests.

  Never write `#` or `###`. Every heading, at any level, becomes a separate \
  top-level entry, so a `###` you meant as a sub-chunk arrives as a sibling of \
  the `##` above it and the nesting you intended is gone. **Depth is expressed \
  by list indentation, never by heading level.** A chunk that needs sub-chunks \
  gets nested list items, not deeper headings.

  Rules:
  - Break down the work the document implies. Do not restate the document.
  - A task is one person's next piece of work, not a phase and not a whole \
  feature.
  - Say what the task is, not how to do it. The person doing it decides that.
  - Write in the same language as the document.
  - Never invent work the document gives no reason for. If a section implies \
  nothing to do, it gets no task.
  - Reply with the Markdown alone. No preamble, no explanation, no summary.

  Example of the shape:

  ## 灰度发布
  - 接入十分之一流量
    - 完成标准：错误率不高于基线
  - 加监控看板
    - 错误率曲线
    - 延迟分位数

  ## 回滚
  - 做一个一键切回的开关
  """

  @doc """
  Asks a model to break `input` down into a task list.

  Options:

    * `:provider` / `:model` / `:thinking` -- the actor to answer as, taken
      from whoever holds the `decomposition_actor` role. Both a provider and a
      model, or neither.
    * `:timeout` -- wall clock for the whole call, default from configuration
    * `:on_chunk` -- called with each piece of output as it arrives. For
      showing somebody that something is happening; the return value is
      ignored and the breakdown is still answered whole. Omit it and nothing
      is watching, which is a legitimate way to call this.

  Failure is reported and never papered over -- see the moduledoc. A call that
  runs out of time answers `{:error, :timeout}` and **discards what it had**,
  even though a listener has already seen some of it: half a breakdown is not
  a smaller breakdown, and returning one would file it as an answer.
  """
  @impl Behaviour
  @spec generate(input(), [opt()]) :: {:ok, String.t()} | {:error, error()}
  def generate(input, opts \\ []) do
    session_dir =
      Path.join(System.tmp_dir!(), "rinto-pmo-pi-wbs-#{System.unique_integer([:positive])}")

    File.mkdir_p!(session_dir)

    try do
      run(input, session_dir, opts)
    after
      File.rm_rf(session_dir)
    end
  end

  # Not `OSProcess.run/1`, which collects everything and answers once. The
  # output has to be passed on as it arrives, so this drives the process
  # directly and mirrors what `run/1` does around the receive loop.
  #
  # `:raw` rather than `:lines`: a person watching wants text appearing, not
  # tidy units, and raw frames cannot strand a last line that never got its
  # newline. Whoever is listening concatenates.
  defp run(input, session_dir, opts) do
    id = "rinto-pmo-wbs-#{System.unique_integer([:positive, :monotonic])}"

    args =
      [
        "--print",
        "--mode",
        "text",
        "--no-session",
        "--no-tools",
        "--session-dir",
        session_dir,
        "--system-prompt",
        @system_prompt
      ] ++ model_args(opts) ++ [user_message(input)]

    start_opts = [
      id: id,
      cmd: executable(),
      args: args,
      owner: self(),
      framing: :raw
    ]

    case OSProcess.start(start_opts) do
      {:ok, _pid} ->
        # pi is given its prompt as an argument and reads nothing, but a child
        # holding an open stdin it will never read is a child that can wait
        # forever for one.
        _ = OSProcess.close_stdin(id)
        collect(id, deadline(timeout(opts)), on_chunk(opts), [], [])

      {:error, {:executable_not_found, _cmd}} ->
        {:error, :pi_not_found}

      {:error, reason} ->
        {:error, {:spawn_failed, reason}}
    end
  end

  defp collect(id, deadline, on_chunk, stdout, stderr) do
    case remaining(deadline) do
      :expired ->
        give_up(id)

      wait ->
        receive do
          {:os_process, ^id, {:stdout, data}} ->
            on_chunk.(data)
            collect(id, deadline, on_chunk, [data | stdout], stderr)

          {:os_process, ^id, {:stderr, data}} ->
            collect(id, deadline, on_chunk, stdout, [data | stderr])

          {:os_process, ^id, {:exit, status}} ->
            finish(status, stdout, stderr)
        after
          wait -> give_up(id)
        end
    end
  end

  # Stopping makes the instance emit its final event; draining keeps the
  # leftovers out of a mailbox where nothing would ever read them. What was
  # produced before the deadline is dropped on purpose -- half a breakdown is
  # not a smaller breakdown, and passing one back would file it as an answer.
  defp give_up(id) do
    _ = OSProcess.stop(id)
    _ = drain(id)
    {:error, :timeout}
  end

  defp drain(id) do
    receive do
      {:os_process, ^id, {:exit, _status}} -> :ok
      {:os_process, ^id, _event} -> drain(id)
    after
      100 -> :ok
    end
  end

  defp finish({:exit, 0}, stdout, _stderr) do
    case stdout |> Enum.reverse() |> IO.iodata_to_binary() |> String.trim() do
      "" -> {:error, :empty_output}
      markdown -> {:ok, markdown}
    end
  end

  # Whatever the provider complained about -- a context window, a key, a rate
  # limit -- pi prints on stderr and exits non-zero.
  #
  # The complaint is **carried back**, not merely logged. It was logged only at
  # first, on the reasoning that the caller can act on "there is no breakdown"
  # and nothing more. That was wrong, and the first real failure showed it: the
  # attempt recorded `{:pi_exit, 1}`, which tells the person waiting nothing at
  # all, while the one sentence that would have told them everything sat in a
  # log they were not reading. It is still logged, for whoever is reading logs.
  defp finish({:exit, code}, _stdout, stderr) do
    complaint = stderr |> Enum.reverse() |> IO.iodata_to_binary() |> String.trim()
    Logger.warning("wbs generation: pi exited #{code}: #{complaint}")
    {:error, {:pi_exit, code, complaint |> message_of() |> truncate()}}
  end

  defp finish(status, _stdout, _stderr), do: {:error, {:spawn_failed, status}}

  # What a provider refuses with arrives as `429: {"type":…,"message":"…"}` --
  # a status, then the response body whole. Only the `message` is kept: it
  # already says what happened in words a person can act on, while the status
  # is a fact about transport that they cannot. The whole line is in the log
  # for whoever is debugging the transport.
  #
  # This is the one piece of provider output this module reads, and it is
  # written so that reading it wrong costs nothing: anything that is not a JSON
  # object carrying a string `message` is passed through exactly as it came,
  # which is what happened before this existed. So a provider changing its
  # shape degrades to verbatim rather than to silence, and there is no
  # vocabulary here to drift out of date.
  defp message_of(complaint) do
    with [json] <- Regex.run(~r/\{.*\}/s, complaint),
         {:ok, %{"message" => message}} when is_binary(message) <- JSON.decode(json) do
      message
    else
      _not_a_message_we_recognise -> complaint
    end
  end

  # A provider that decides to print a stack trace should not put one in a
  # field somebody reads in a panel. The whole of it is in the log.
  @complaint_limit 2_000

  defp truncate(complaint) when byte_size(complaint) <= @complaint_limit, do: complaint

  defp truncate(complaint) do
    String.slice(complaint, 0, @complaint_limit) <> "… (truncated; the whole of it is in the log)"
  end

  # Absent means nobody is watching, which is a legitimate way to call this --
  # the streaming is for a person, not for the result.
  defp on_chunk(opts) do
    case Keyword.get(opts, :on_chunk) do
      callback when is_function(callback, 1) -> callback
      _absent -> fn _chunk -> :ok end
    end
  end

  defp deadline(:infinity), do: :infinity
  defp deadline(timeout), do: System.monotonic_time(:millisecond) + timeout

  defp remaining(:infinity), do: :infinity

  defp remaining(deadline) do
    case deadline - System.monotonic_time(:millisecond) do
      left when left > 0 -> left
      _expired -> :expired
    end
  end

  # Which model breaks documents down is a runtime choice, like naming: it is
  # whichever actor holds the role. Unlike naming there is no inheriting from a
  # topic, so a caller with neither provider nor model has already decided to
  # let pi pick -- see `RintoPMO.Documents` for who refuses before it gets here.
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

  # JSON rather than prose, so that a document which itself reads like an
  # instruction arrives as a value in a field and not as a line of the prompt.
  defp user_message(input) do
    JSON.encode!(%{"title" => input.title, "blocks" => input.blocks})
  end

  # Long by the standards of the other model call in this system, and it should
  # be: this one reads a whole document before it writes anything, and a person
  # is watching the spinner rather than waiting on something else.
  defp timeout(opts), do: Keyword.get(opts, :timeout) || setting(:timeout) || 180_000

  defp executable, do: Application.get_env(:rinto_pmo, :pi_executable, "pi")

  defp setting(key) do
    :rinto_pmo
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(key)
  end
end
