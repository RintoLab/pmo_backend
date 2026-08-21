defmodule RintoPMO.Agent.TaskEstimator do
  @moduledoc """
  Rates a task's difficulty, or produces its three-point estimate, with one
  short-lived model call.

  Built the same way as `RintoPMO.Agent.WbsGenerator` and for the same
  reasons: its own `pi --print` process, asked once, read off stdout, let go.
  Sending this down a topic's own session would put a question nobody asked
  into the context a person is talking into.

  ## There is no fallback

  A topic that misses its one chance to be named can be named from its first
  message instead. Nothing corresponds to that here: an estimate nobody could
  produce is not recoverable by inventing one, and a made-up number written
  onto a task is far worse than saying so. Every failure is `{:error, reason}`
  and every reason is passed along as it came.

  ## What comes back

  A JSON array of objects, one per task that was asked about. This module
  unwraps the model's answer and checks that it *is* an array of objects; what
  the objects mean -- Fibonacci points, ordered minutes -- is settled where
  the values are written, `RintoPMO.Tasks`. A shape it refuses is a generation
  to redo, not a number to guess.
  """

  alias RintoPMO.Agent.Print

  @typedoc """
  One work item as the model sees it. `id` is the task's, as a string, so the
  answer can name it back.
  """
  @type task_input :: %{
          required(:id) => String.t(),
          required(:title) => String.t(),
          optional(:description) => String.t() | nil,
          optional(:difficulty) => pos_integer() | nil
        }

  @typedoc """
  A completed task from the same project, for calibrating a time estimate.
  """
  @type history_item :: %{
          required(:title) => String.t(),
          required(:actual_minutes) => non_neg_integer(),
          optional(:difficulty) => pos_integer() | nil,
          optional(:estimate) => map() | nil
        }

  @type difficulty_input :: %{required(:tasks) => [task_input()]}

  @type time_input :: %{
          required(:tasks) => [task_input()],
          required(:history) => [history_item()]
        }

  @type item :: %{optional(String.t()) => term()}

  @type opt :: Print.opt()

  @type error :: Print.error() | :invalid_output

  defmodule Behaviour do
    @moduledoc """
    One round trip to a model, for numbers and nothing else.

    Exists so that everything around the call -- which tasks are unfilled, the
    in-flight slot, the conditional write -- is testable without a model.
    """

    alias RintoPMO.Agent.TaskEstimator

    @callback estimate_difficulty(TaskEstimator.difficulty_input(), [TaskEstimator.opt()]) ::
                {:ok, [TaskEstimator.item()]} | {:error, TaskEstimator.error()}

    @callback estimate_time(TaskEstimator.time_input(), [TaskEstimator.opt()]) ::
                {:ok, [TaskEstimator.item()]} | {:error, TaskEstimator.error()}
  end

  @behaviour Behaviour

  @difficulty_prompt """
  You assign Fibonacci story points to software tasks. You are given JSON: a \
  list of tasks, each with an id, a title, and a description. Reply with a \
  JSON array that rates them.

  Allowed values, and only these: 1, 2, 3, 5, 8, 13, 21.

  - 1 -- trivial. A rename, a one-line fix, copying a known pattern.
  - 2 -- small. A few files, the path is obvious.
  - 3 -- straightforward. A contained change, some looking around.
  - 5 -- meaty. Several moving parts, or an unfamiliar corner.
  - 8 -- large. Cross-cutting, or the design is still load-bearing.
  - 13 -- very large. Several areas at once, or the unknowns are the work.
  - 21 -- too big. Should probably be split; rate it 21 rather than inventing \
  a bigger number.

  This is a rating of the work as written, not a guess at how many minutes it \
  will take. Time is a different question.

  Shape, and follow it exactly:

  [{"id": "<the task id you were given>", "difficulty": 5}]

  Rules:
  - One object per task you were given. Skip none, add none.
  - Use only the allowed values.
  - Never invent tasks or ids.
  - Reply with the JSON array alone. No markdown fence, no preamble, no \
  trailing explanation.
  """

  @time_prompt """
  You produce three-point time estimates, in minutes, for software tasks. You \
  are given JSON: the tasks to estimate, and a history of completed work from \
  the same project (title, difficulty, the estimate that was given then, and \
  how many minutes it actually took). Reply with a JSON array.

  Minutes, whole numbers, all three or the estimate is useless. optimistic is \
  everything going right; likely is the usual path; pessimistic includes the \
  trouble this kind of work hits. They must satisfy optimistic <= likely <= \
  pessimistic.

  Use the history to calibrate. When the new work looks like something that \
  has been done, match that sample's actuals rather than a generic guess. \
  When history is empty, estimate from the task alone. Difficulty, when \
  present, is a Fibonacci story point (1, 2, 3, 5, 8, 13, 21) and is the \
  closest thing to a size class.

  Shape, and follow it exactly:

  [{"id": "<the task id you were given>", "optimistic": 30, "likely": 60, \
  "pessimistic": 120}]

  Rules:
  - One object per task you were given. Skip none, add none.
  - Minutes. Never hours, never days.
  - Never invent tasks or ids.
  - Reply with the JSON array alone. No markdown fence, no preamble, no \
  trailing explanation.
  """

  @doc """
  Asks a model to rate each task's difficulty.
  """
  @impl Behaviour
  @spec estimate_difficulty(difficulty_input(), [opt()]) ::
          {:ok, [item()]} | {:error, error()}
  def estimate_difficulty(input, opts \\ []) do
    generate(@difficulty_prompt, input, opts)
  end

  @doc """
  Asks a model for a three-point estimate of each task, in minutes.
  """
  @impl Behaviour
  @spec estimate_time(time_input(), [opt()]) :: {:ok, [item()]} | {:error, error()}
  def estimate_time(input, opts \\ []) do
    generate(@time_prompt, input, opts)
  end

  @doc false
  @spec decode_items(String.t()) :: {:ok, [item()]} | {:error, :invalid_output}
  def decode_items(text) when is_binary(text) do
    with {:ok, json} <- extract_json(text),
         {:ok, decoded} <- JSON.decode(json),
         true <- json_array_of_objects?(decoded) do
      {:ok, Enum.map(decoded, &stringify_keys/1)}
    else
      _invalid -> {:error, :invalid_output}
    end
  end

  defp generate(prompt, input, opts) do
    opts =
      opts
      |> Keyword.put_new(:name, "estimate")
      |> Keyword.put_new(:idle_timeout, idle_timeout())

    case Print.run(prompt, JSON.encode!(input), opts) do
      {:ok, text} -> decode_items(text)
      {:error, _reason} = error -> error
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

  defp json_array_of_objects?(decoded) when is_list(decoded), do: Enum.all?(decoded, &is_map/1)
  defp json_array_of_objects?(_decoded), do: false

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {to_string(key), value} end)
  end

  defp idle_timeout do
    :rinto_pmo
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:idle_timeout, 180_000)
  end
end
