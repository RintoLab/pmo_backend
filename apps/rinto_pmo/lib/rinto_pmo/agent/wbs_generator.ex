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

  @type error ::
          :pi_not_found
          | :timeout
          | :empty_output
          | {:pi_exit, non_neg_integer()}
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

  Shape:
  - `##` heading -- a chunk of work, covering the tasks under it.
  - `-` list item under a heading -- one task somebody can pick up and finish.
  - Indented `-` under a task -- what "done" means for it, if it is not obvious \
  from the title alone.

  Rules:
  - Break down the work the document implies. Do not restate the document.
  - A task is one person's next piece of work, not a phase and not a whole \
  feature.
  - Say what the task is, not how to do it. The person doing it decides that.
  - Write in the same language as the document.
  - Never invent work the document gives no reason for. If a section implies \
  nothing to do, it gets no task.
  - Reply with the Markdown alone. No preamble, no explanation, no summary.
  """

  @doc """
  Asks a model to break `input` down into a task list.

  Options:

    * `:provider` / `:model` / `:thinking` -- the actor to answer as, taken
      from whoever holds the `decomposition_actor` role. Both a provider and a
      model, or neither.
    * `:timeout` -- wall clock for the whole call, default from configuration

  Failure is reported and never papered over -- see the moduledoc.
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

  defp run(input, session_dir, opts) do
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

    [cmd: executable(), args: args, timeout: timeout(opts)]
    |> OSProcess.run()
    |> interpret()
  end

  defp interpret({:ok, %{status: {:exit, 0}, stdout: stdout}}) do
    case String.trim(stdout) do
      "" -> {:error, :empty_output}
      markdown -> {:ok, markdown}
    end
  end

  # Whatever the provider complained about -- a context window, a key, a rate
  # limit -- pi prints on stderr and exits non-zero. It is logged rather than
  # returned because the reason a caller can act on is "there is no breakdown";
  # what to tell the person waiting is stamped where the job is recorded.
  defp interpret({:ok, %{status: {:exit, code}, stderr: stderr}}) do
    Logger.warning("wbs generation: pi exited #{code}: #{String.trim(stderr)}")
    {:error, {:pi_exit, code}}
  end

  defp interpret({:ok, %{status: status}}), do: {:error, {:spawn_failed, status}}
  defp interpret({:error, {:timeout, _partial}}), do: {:error, :timeout}
  defp interpret({:error, {:executable_not_found, _cmd}}), do: {:error, :pi_not_found}
  defp interpret({:error, reason}), do: {:error, {:spawn_failed, reason}}

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
