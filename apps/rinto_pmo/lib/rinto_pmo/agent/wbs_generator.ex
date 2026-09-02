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

  ## Its clock measures silence, not duration

  Naming is given a wall-clock budget, which suits a call that should take a
  moment. There is no honest budget for this one: what decides how long it
  takes is how much work the document implies, which is the question being
  asked. So a call that is still producing output is left alone however long
  it runs, and what gets cut off is a call that has gone quiet.

  ## It reads pi's event stream, not pi's rendered output

  `--mode json`, and the reason is the paragraph above. `--mode text` prints
  nothing until the process is done: measured against a real provider, a
  19-second answer arrived whole at +19s, and a 78-second breakdown of a 17KB
  document arrived as three pieces at the same instant, 78.594s in. Down a
  pipe there is no partial output at all, so silence and duration are the same
  measurement, and the clock above degenerates into the whole-call budget it
  was written not to be -- which is what killed three real documents, all of
  them large, at exactly the timeout while smaller ones went through.

  `--mode json` writes one JSON object per line as things happen, including
  `thinking_delta` while the model is still thinking, which is where the long
  silences are. Verified against three providers.

  The price is a private format: these events are pi's, they carry no
  compatibility promise, and a pi upgrade may rename them. So nothing here
  depends on reading them *well*:

    * a line that is not JSON, or an event this does not know, is ignored --
      it still counts as the process being alive, which is most of what
      reading it is for
    * the answer is taken from the final `turn_end`, which carries the whole
      message; the `text_delta` pieces are a fallback, so a provider that
      streams nothing still produces a breakdown
    * a failure is read from the same event, see below

  If the event names change, the worst case is the behaviour before this
  existed: no streaming, and one answer at the end.

  ## Failure arrives on stdout now, and exit code 0

  Under `--mode text` a provider that refuses makes pi exit non-zero with the
  complaint on stderr. Under `--mode json` **pi exits 0** and puts the refusal
  in the final `turn_end` as `stopReason: "error"` with an `errorMessage`.
  Both paths are read, because the first is still how pi's own failures
  arrive. Missing the second would turn every provider refusal into
  `:empty_output` and throw away the one sentence the person waiting can act
  on.

  ## There is no fallback

  A topic that misses its one chance to be named can be named from its first
  message instead, so `RintoPMO.Conversations.TitleWorker` treats a model
  failure as an ordinary outcome. Nothing corresponds to that here: a
  breakdown nobody could produce is not recoverable by producing a worse one,
  and inventing a plausible tree is far worse than saying so. Every failure is
  `{:error, reason}` and every reason is passed along as it came.

  ## What comes back

  Markdown -- the model's own answer, unwrapped from the events it arrived in
  -- and this module does not check its shape. What the notation means is
  settled where the task list is read -- `RintoPMO.Tasks.Breakdown` -- and a
  shape it refuses is a document to fix rather than a generation to redo, so
  the complaint belongs at filing time where somebody can act on it. The
  system prompt here and that parser are the two halves of one convention and
  move together.
  """

  alias RintoPMO.Agent.Events
  alias RintoPMO.Agent.PiInstallation
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
          | {:idle_timeout, timeout()}
          | {:on_chunk, (String.t() -> any())}

  @type error ::
          :pi_not_found
          | :stalled
          | :empty_output
          | {:pi_exit, non_neg_integer(), String.t()}
          | {:provider_refused, String.t()}
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

  # The criteria rules below are specific about *shape* and silent about
  # *notation*, and both halves are deliberate.
  #
  # Silent about notation because `RintoPMO.Tasks.Breakdown` reads everything
  # under a heading as one description: a `**验收:**` marker would be a second
  # convention with no parser and no reader behind it. What a bullet means is
  # settled here, in the writing, and stays a convention a person reads rather
  # than a field anything queries.
  #
  # Specific about shape because the loose version -- "put the acceptance
  # criteria here too, in whatever wording fits" -- produced bodies where
  # bullets carried content and criteria indistinguishably: a list of the two
  # routes to add, sitting in the same notation as what has to be true when they
  # work. Saying a bullet *is* a criterion gives the notation one job, and it is
  # the same move `Breakdown` already makes for headings -- what would have been
  # a smaller task is written as another `###` rather than inferred.
  #
  # The last rule is load-bearing. Without it the demand for criteria collides
  # with "never invent work the document gives no reason for": asked for a
  # criterion on every task, a model supplies one, and an invented acceptance
  # criterion is a requirement nobody agreed to. The example keeps a task with
  # none for the same reason.
  @system_prompt """
  You break a plan down into the work it implies. You are given a document as \
  JSON: a title, and its sections in order. Reply with the work breakdown as \
  Markdown.

  Shape, and follow it exactly:

  - `##` -- a chunk of work. Everything in the reply lives under one of these.
  - `###` -- one task somebody can pick up and finish. Belongs to the `##` \
  above it.
  - Text under either heading -- what that chunk or task is, and then how \
  somebody will know it is done. Nothing marks the boundary: the criteria are \
  the bullets at the end.

  A chunk that is one single task is written as a `##` with **no `###` under \
  it**, and the text under it describes that task. Do not write a `##` and then \
  a single `###` saying the same thing.

  Never write `#`, and never write `####` or deeper. Every `###` must sit under \
  a `##`; a `###` before the first `##` is refused outright.

  Acceptance criteria:

  - **A bullet is a criterion, and nothing else is a bullet.** Anything that is \
  not a criterion goes in the prose above them -- and if it was a piece of work, \
  it was a task and belongs in its own `###`.
  - A criterion says what is **observably true once the work is finished**. Not \
  what the doer will do, not that a test exists, not what somebody downstream \
  can then build. "The list keeps its scroll position across a reload" is a \
  criterion; "handle scroll position" is the title again; "add tests for it" is \
  the doer's business.
  - One line each, and each one has to be settleable by looking at the result. \
  A line nobody could call true or false is not a criterion.
  - Take them from the document. A task the document gives no grounds for gets \
  none: an invented criterion is a requirement nobody agreed to.

  Rules:
  - Break down the work the document implies. Do not restate the document.
  - A task is one person's next piece of work, not a phase and not a whole \
  feature.
  - Say what the task is, not how to do it. The person doing it decides that.
  - Write in the same language as the document.
  - Never invent work the document gives no reason for. If a section implies \
  nothing to do, it gets no task.
  - Do not estimate. How long something takes is decided elsewhere.
  - Reply with the Markdown alone. No preamble, no explanation, no summary.

  Example of the shape:

  ## 灰度发布

  ### 接入十分之一流量

  先切 10% 流量，观察一个完整工作日。

  - 错误率不高于基线
  - 回滚演练跑通一次

  ### 加监控看板

  错误率曲线、延迟分位数各一块，两块都按服务维度拆开。

  - p99 越过告警线时告警真的发得出来，不是只画了一条线

  ## 把回滚做成一个开关

  现在回滚要手动改配置再重启。做成一键切回，不需要发布。
  """

  @doc """
  Asks a model to break `input` down into a task list.

  Options:

    * `:provider` / `:model` / `:thinking` -- the actor to answer as, taken
      from whoever holds the `decomposition_actor` role. Both a provider and a
      model, or neither.
    * `:idle_timeout` -- how long the call may produce nothing before it is
      treated as dead. Not a budget for the whole call, which has none.
    * `:on_chunk` -- called with each piece of output as it arrives. For
      showing somebody that something is happening; the return value is
      ignored and the breakdown is still answered whole. Omit it and nothing
      is watching, which is a legitimate way to call this.

  Failure is reported and never papered over -- see the moduledoc. A call that
  goes quiet answers `{:error, :stalled}` and **discards what it had**, even
  though a listener has already seen some of it: half a breakdown is not a
  smaller breakdown, and returning one would file it as an answer.
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
  # `:lines` rather than `:raw`: what arrives is one JSON object per line and a
  # half-read object says nothing at all, so the framing that used to be wrong
  # here -- tidy units instead of text appearing -- is now the only one that
  # parses. What a watcher sees is unaffected: the pieces handed on are the
  # model's own deltas, which are finer than lines anyway.
  defp run(input, session_dir, opts) do
    id = "rinto-pmo-wbs-#{System.unique_integer([:positive, :monotonic])}"

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
        @system_prompt
      ] ++ model_args(opts) ++ [user_message(input)]

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
        # pi is given its prompt as an argument and reads nothing, but a child
        # holding an open stdin it will never read is a child that can wait
        # forever for one.
        _ = OSProcess.close_stdin(id)
        collect(id, idle_timeout(opts), on_chunk(opts), %{deltas: [], answer: nil, stderr: []})

      {:error, {:executable_not_found, _cmd}} ->
        {:error, :pi_not_found}

      {:error, reason} ->
        {:error, {:spawn_failed, reason}}
    end
  end

  # The clock measures **silence, not duration**. Every piece of output starts
  # it again, which the `after` clause does for free by virtue of this being a
  # fresh `receive` each time round.
  #
  # A budget for the whole call would be a guess at how much breakdown somebody
  # is entitled to, and there is no honest number for that: what decides how
  # long this takes is how much work the document implies, which is the
  # question being asked. A model that is still producing is still working, and
  # cutting it off mid-answer throws away everything it has done. What is worth
  # catching is the call that has stopped -- a provider that accepted the
  # request and went quiet -- and silence is exactly what that looks like.
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

  # One line of pi's event stream, read through `RintoPMO.Agent.Events` --
  # which is where the names live, because a conversation reads the same ones
  # down a different transport.
  #
  # Anything unrecognised is dropped on the floor, deliberately: a line this
  # cannot read has still done the one thing every line does, which is prove
  # the call is alive.
  #
  # Thinking is dropped the same way, but only after it has reset the clock.
  # It is not handed on: a person waiting for a task list has not asked to
  # watch the model talk itself into one.
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

      # Later turns win: `--print` with no tools makes one, and if that ever
      # stops being true the last word is the right one to keep.
      nil ->
        %{acc | answer: Events.finished_message(frame) || acc.answer}
    end
  end

  # Stopping makes the instance emit its final event; draining keeps the
  # leftovers out of a mailbox where nothing would ever read them. What was
  # produced before it went quiet is dropped on purpose -- half a breakdown is
  # not a smaller breakdown, and passing one back would file it as an answer.
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

  # Exit 0 is not success: under `--mode json` it is also how a provider
  # refusal comes back. The refusal is checked first, because a refused turn
  # carries no text and would otherwise be reported as an empty answer -- true,
  # useless, and hiding the sentence that says why.
  defp finish({:exit, 0}, acc) do
    case refusal(acc.answer) do
      nil ->
        case answer(acc) do
          "" -> {:error, :empty_output}
          markdown -> {:ok, markdown}
        end

      complaint ->
        Logger.warning("wbs generation: the provider refused: #{complaint}")
        {:error, {:provider_refused, complaint |> message_of() |> truncate()}}
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
  defp finish({:exit, code}, acc) do
    complaint = acc.stderr |> Enum.reverse() |> IO.iodata_to_binary() |> String.trim()
    Logger.warning("wbs generation: pi exited #{code}: #{complaint}")
    {:error, {:pi_exit, code, complaint |> message_of() |> truncate()}}
  end

  defp finish(status, _acc), do: {:error, {:spawn_failed, status}}

  # The model's answer: the finished message when there is one, and otherwise
  # what was streamed. Both, rather than either, and in that order -- the
  # finished message is the whole of it by definition, while the deltas are
  # what a provider that streams nothing would leave us with. A run where both
  # are empty is an empty answer, which is reported as one.
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

  # How long a call may say nothing before it is treated as dead. Not how long
  # it may take -- see `collect/4`.
  #
  # Three minutes, and it is a measurement again rather than a stand-in: with
  # the event stream, a healthy call is never quiet for long, because thinking
  # emits deltas too. It was briefly ten, to stop `--mode text` -- which said
  # nothing at all until it was done -- from killing every large document; that
  # is what the move to `--mode json` fixed, so the number comes back down.
  #
  # What it still cannot tell apart is a dead provider from a live one that
  # streams nothing whatsoever. Such a provider is capped at three minutes of
  # work here. Three were measured and all three stream, so that is a corner
  # rather than a case -- and the day one turns up, this is the number to
  # revisit, not the loop.
  defp idle_timeout(opts) do
    Keyword.get(opts, :idle_timeout) || setting(:idle_timeout) || 180_000
  end

  defp executable, do: Application.get_env(:rinto_pmo, :pi_executable, "pi")

  defp setting(key) do
    :rinto_pmo
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(key)
  end
end
