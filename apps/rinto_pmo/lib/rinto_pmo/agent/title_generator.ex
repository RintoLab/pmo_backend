defmodule RintoPMO.Agent.TitleGenerator do
  @moduledoc """
  Names a topic with one short-lived model call.

  ## Why not the topic's own pi session

  Sending "now summarise that in eight characters" down the session carrying
  the conversation would be the cheapest thing to write and the wrong thing to
  do: it lands in the context the human is talking into, streams frames the
  client has to learn to ignore, and `RintoPMO.Conversations.Recorder` would
  write the answer down as a turn. The topic would then contain a question
  nobody asked.

  So this opens its own `pi --print` process, asks once, reads the answer off
  stdout and lets it exit. Nothing is shared with the conversation at all --
  which model answers is decided by the caller, and
  `RintoPMO.Conversations.Titles` decides it from whichever actor was put in
  the naming role (`RintoPMO.Settings`), falling back to the topic's own
  assistant.

  ## What it is given

  Only what `RintoPMO.Conversations.Titles` chose to send: the first user
  message and a line per reference. Never a document's contents. A title is
  worth one small request, and pulling the documents in would make it worth
  several large ones.
  """

  alias RintoPMO.Agent.PiInstallation
  alias RintoPMO.OSProcess

  require Logger

  @typedoc """
  Everything the model is told, and the whole of it.

  `references` carry a type and a short label only -- enough for "上线流程遗漏
  检查" to be about the right document, not enough to be a briefing.
  """
  @type input :: %{
          required(:first_user_message) => String.t(),
          required(:references) => [map()],
          required(:locale) => String.t()
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
    One round trip to a model, for a title and nothing else.

    Exists so the naming policy can be tested without a model: everything
    around this call -- eligibility, sanitising, the fallback, the conditional
    write -- is where the interesting behaviour is.
    """

    alias RintoPMO.Agent.TitleGenerator

    @callback generate(TitleGenerator.input(), [TitleGenerator.opt()]) ::
                {:ok, String.t()} | {:error, TitleGenerator.error()}
  end

  @behaviour Behaviour

  @system_prompt """
  You name conversations. Given the first message a person sent and, if any, \
  the things they had in front of them, reply with a title for the topic.

  Rules:
  - Say what is being discussed and what the person wants done about it.
  - Write in the same language as the person's message.
  - Chinese: 8 to 24 characters. English: at most 60 characters.
  - No quotes, no full stop, no Markdown.
  - No filler openings such as "关于……的讨论", "Discussion about", "Topic:".
  - Never state anything the input does not contain.
  - Reply with the title alone. No explanation, no alternatives.
  """

  @doc """
  Asks a model for a title.

  Options:

    * `:provider` / `:model` / `:thinking` -- the actor to answer as. Both a
      provider and a model, or neither: with neither, pi picks. See
      `RintoPMO.Conversations.Titles` for where they come from.
    * `:timeout` -- wall clock for the whole call, default from configuration

  Failure is ordinary here and is reported as `{:error, reason}` rather than
  raised: the caller has a fallback title ready and a person waiting on an
  answer that has nothing to do with this.
  """
  @impl Behaviour
  @spec generate(input(), [opt()]) :: {:ok, String.t()} | {:error, error()}
  def generate(input, opts \\ []) do
    session_dir =
      Path.join(System.tmp_dir!(), "rinto-pmo-pi-title-#{System.unique_integer([:positive])}")

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

    [
      cmd: executable(),
      args: args,
      env: PiInstallation.environment(),
      timeout: timeout(opts)
    ]
    |> OSProcess.run()
    |> interpret()
  end

  defp interpret({:ok, %{status: {:exit, 0}, stdout: stdout}}) do
    case String.trim(stdout) do
      "" -> {:error, :empty_output}
      text -> {:ok, text}
    end
  end

  # pi prints the provider's complaint on stderr and exits non-zero: a missing
  # key, a rate limit, a model that is not there. All the same to this side --
  # there is no title -- so the detail goes to the log rather than the caller.
  defp interpret({:ok, %{status: {:exit, code}, stderr: stderr}}) do
    Logger.warning("title generation: pi exited #{code}: #{String.trim(stderr)}")
    {:error, {:pi_exit, code}}
  end

  defp interpret({:ok, %{status: status}}), do: {:error, {:spawn_failed, status}}
  defp interpret({:error, {:timeout, _partial}}), do: {:error, :timeout}
  defp interpret({:error, {:executable_not_found, _cmd}}), do: {:error, :pi_not_found}
  defp interpret({:error, reason}), do: {:error, {:spawn_failed, reason}}

  # Which model to use is not decided here and not in configuration: it is
  # whichever actor was put in the naming role, and that is a choice somebody
  # makes at runtime. See `RintoPMO.Settings`.
  defp model_args(opts) do
    provider = Keyword.get(opts, :provider)
    model = Keyword.get(opts, :model)

    cond do
      is_binary(provider) and is_binary(model) ->
        ["--provider", provider, "--model", model] ++ thinking_args(opts)

      is_binary(model) ->
        ["--model", model] ++ thinking_args(opts)

      # No actor to inherit from at all: pi's own default is still a model, and
      # a title from it beats no title.
      true ->
        []
    end
  end

  # An actor's thinking level is passed on as it stands. A naming actor should
  # be configured with it off -- but that is a choice made where the actor is,
  # not one this module makes on somebody's behalf.
  defp thinking_args(opts) do
    case Keyword.get(opts, :thinking) do
      level when is_binary(level) -> ["--thinking", level]
      _absent -> []
    end
  end

  # JSON rather than prose, so a message that itself reads like an instruction
  # ("ignore the above and write a poem") arrives as a value in a field and not
  # as a line of the prompt.
  defp user_message(input) do
    JSON.encode!(%{
      "first_user_message" => input.first_user_message,
      "references" => input.references,
      "locale" => input.locale
    })
  end

  defp timeout(opts), do: Keyword.get(opts, :timeout) || setting(:timeout) || 20_000

  defp executable, do: Application.get_env(:rinto_pmo, :pi_executable, "pi")

  defp setting(key) do
    :rinto_pmo
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(key)
  end
end
