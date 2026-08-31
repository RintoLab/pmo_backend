defmodule RintoPMO.Agent.DocumentReviewer do
  @moduledoc """
  Reads documents end to end and says what is wrong with them, in one model call.

  Built the same way as `RintoPMO.Agent.AnnotationResponder` and for the same
  reasons: its own `pi --print` process, asked once, read off stdout, let go.

  ## It answers about a set, not about a document

  The interesting findings are the ones no single document contains. "This says
  the status field has three values and that one says it has two" cannot be
  reached by reviewing either document alone, and reviewing them one after
  another and comparing afterwards puts the comparison back on the person who
  asked. So the input is a list, a one-document review is a list of one, and
  every finding names the document it is about.

  ## Parsed, unlike a reply

  `AnnotationResponder` is the one call in this system whose answer is not
  parsed, because an opinion in a thread has no shape to fail. This one does: a
  finding has to be placed -- on a document, usually on a block -- before
  anybody can see it, and a placement can be wrong. So JSON, and a shape that is
  checked.

  What this module checks is only that the answer *is* a list of objects. Which
  document each finding names, and whether the block it names exists, is settled
  where the annotations are written -- `RintoPMO.Annotations` -- because that is
  where the documents are, and because a finding pointing at a block that has
  since gone is a thing to degrade rather than a generation to redo.

  ## Why it is capped

  The prompt asks for the most important findings and no more than
  `max_findings/0`. A review is worth having because somebody reads all of it;
  forty notes arriving at once on a document sized for the handful a person
  leaves is a workspace nobody can use, and the model will happily produce
  forty. The cap is in the prompt and again where the findings are written,
  because a prompt is a request rather than a constraint.
  """

  alias RintoPMO.Agent.Print

  @max_findings 12

  @typedoc """
  One document as the reviewer sees it: its id, its title, and its blocks with
  the ids a finding will name them back by.
  """
  @type document_input :: %{
          required(:id) => String.t(),
          required(:title) => String.t(),
          required(:blocks) => [%{required(:id) => String.t(), required(:text) => String.t()}]
        }

  @type input :: %{required(:documents) => [document_input()]}

  @typedoc """
  One finding, as it came back. Keys are strings and nothing here has been
  checked beyond the object being an object.
  """
  @type item :: %{optional(String.t()) => term()}

  @type opt :: Print.opt() | {:system_prompt, String.t() | nil}

  @type error :: Print.error() | :invalid_output

  defmodule Behaviour do
    @moduledoc """
    One round trip to a model, for a list of findings and nothing else.

    Exists so that everything around the call -- the role lookup, placing each
    finding, writing the annotations -- is testable without a model.
    """

    alias RintoPMO.Agent.DocumentReviewer

    @callback review(DocumentReviewer.input(), [DocumentReviewer.opt()]) ::
                {:ok, [DocumentReviewer.item()]} | {:error, DocumentReviewer.error()}
  end

  @behaviour Behaviour

  @prompt """
  You are reviewing design documents for a team that has to build from them. \
  You are given JSON: one or more documents, each with an id, a title, and its \
  blocks in order, every block carrying an id.

  Read all of it before writing anything. Then report what is wrong.

  What is worth reporting:

  - **Contradictions.** Two places that cannot both be true. Across documents \
  is the most valuable kind: you were given them together because nobody \
  reading one alone would find it.
  - **Decisions that were never made.** A design that names a mechanism without \
  saying what it does in the case that will actually happen.
  - **Statements that will mislead somebody building from this**, including \
  text that has been overtaken by a decision recorded elsewhere in what you \
  were given.
  - **Gaps that matter.** Not everything absent is a gap; a document is allowed \
  to have a scope.

  What is not worth reporting: wording, tone, formatting, section order, or \
  anything you would preface with "consider". Nobody clicked this button to be \
  told a paragraph could be tightened.

  Place each finding on the document that should change, and on the block it is \
  about. When two documents contradict each other, decide which one is wrong \
  and put the finding there, citing the other as `rinto://document/<id>` in \
  your text -- that is a live link in this system, so use the id you were \
  given and nothing else. Use a null block_id only when the finding is about \
  the document as a whole.

  Shape, and follow it exactly:

  [{"document_id": "<a document id you were given>", \
  "block_id": "<a block id from that document, or null>", \
  "content": "<what is wrong, in prose>"}]

  Rules:
  - At most #{@max_findings} findings. If you have more, report the ones that \
  would cost the most to discover later.
  - Never invent an id. Every document_id and block_id must be one you were \
  given.
  - Each finding stands alone: say what is wrong and why it matters. Do not \
  number them, do not refer to "the previous point", do not write a summary \
  finding.
  - Say the problem, not the edit. You cannot change these documents and \
  nothing you write will be applied -- somebody reads each of these and \
  decides.
  - Nothing wrong is a real answer. Reply with `[]` rather than filling the \
  list.
  - Reply with the JSON array alone. No markdown fence, no preamble, no \
  trailing explanation.
  """

  @doc """
  The most findings one review may leave behind.
  """
  @spec max_findings() :: pos_integer()
  def max_findings, do: @max_findings

  @doc """
  Asks a model to review a set of documents.
  """
  @impl Behaviour
  @spec review(input(), [opt()]) :: {:ok, [item()]} | {:error, error()}
  def review(input, opts \\ []) do
    {custom_prompt, opts} = Keyword.pop(opts, :system_prompt)

    opts =
      opts
      |> Keyword.put_new(:name, "review")
      |> Keyword.put_new(:idle_timeout, idle_timeout())

    case Print.run(prompt(custom_prompt), JSON.encode!(input), opts) do
      {:ok, text} -> Print.decode_objects(text)
      {:error, _reason} = error -> error
    end
  end

  # An actor's prompt customises what the reviewer pays attention to, while
  # the built-in contract remains responsible for ids, placement and JSON. A
  # fully replaceable prompt would also make the storage protocol replaceable,
  # and a prose answer cannot be turned into annotations honestly.
  defp prompt(nil), do: @prompt
  defp prompt(""), do: @prompt

  defp prompt(custom_prompt) when is_binary(custom_prompt) do
    """
    #{@prompt}

    Additional review instructions from the configured review actor:

    #{custom_prompt}

    Apply those instructions when deciding what is worth reporting. The JSON \
    shape, id rules, finding limit, and output-only requirements above still \
    apply.
    """
  end

  defp idle_timeout do
    :rinto_pmo
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:idle_timeout, 300_000)
  end
end
