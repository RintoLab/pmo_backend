defmodule RintoPMO.Agent.AnnotationResponder do
  @moduledoc """
  Answers one annotation, with one short-lived model call.

  Built the same way as `RintoPMO.Agent.TaskEstimator` and for the same
  reasons: its own `pi --print` process, asked once, read off stdout, let go.
  Sending this into a topic's session would put a question nobody asked into
  the context a person is talking into.

  ## What it is not allowed to do

  It answers in prose and that is all it can do. It cannot change the document,
  cannot propose a change, and cannot close the thread -- proposals come out of
  conversations and confirming is a person's action. So the prompt tells it to
  argue its case rather than to describe an edit it is about to make, because
  the edit is not going to happen from here.

  ## Prose, not JSON

  The one model call in this system whose answer is not parsed. An estimate is
  a number that has to be written into a column, so its shape can be wrong; a
  reply is somebody's opinion in a thread of opinions, and there is no shape
  for it to fail. What comes back is trimmed and stored.

  The refusals that remain are the call's own -- a dead process, a provider
  saying no, silence -- plus `:empty_output`, which `Print` already raises
  because an empty answer is not an opinion.
  """

  alias RintoPMO.Agent.Print

  @typedoc """
  The note being answered, and enough of the document to answer it against.

  `document` is not optional. An annotation routinely says "this contradicts
  the section above", and an answer written without the section above is a
  guess about what the objection meant.
  """
  @type input :: %{
          required(:annotation) => %{
            required(:content) => String.t(),
            required(:replies) => [String.t()],
            optional(:block_text) => String.t() | nil,
            optional(:selected_text) => String.t() | nil
          },
          required(:document) => %{
            required(:title) => String.t(),
            required(:blocks) => [String.t()]
          }
        }

  @type opt :: Print.opt()

  @type error :: Print.error()

  defmodule Behaviour do
    @moduledoc """
    One round trip to a model, for an opinion and nothing else.

    Exists so that everything around the call -- the role lookup, the in-flight
    slot, appending the reply -- is testable without a model.
    """

    alias RintoPMO.Agent.AnnotationResponder

    @callback respond(AnnotationResponder.input(), [AnnotationResponder.opt()]) ::
                {:ok, String.t()} | {:error, AnnotationResponder.error()}
  end

  @behaviour Behaviour

  @prompt """
  You are reviewing a design document with a colleague. You are given JSON: \
  one annotation somebody left on the document, whatever has already been said \
  under it, and the document as it currently stands.

  Answer the annotation. Say whether you think it is right, and why. If you \
  disagree, say so and give the reason; agreeing with everything is not \
  helpful to somebody trying to decide.

  You are writing one reply in a thread, addressed to the people reading that \
  thread.

  - Answer the point that was raised. Do not review the rest of the document.
  - Read the document before answering: an annotation often objects that one \
  part contradicts another, and the answer is in the text you were given.
  - Concrete beats hedged. If the right answer is "the second paragraph should \
  say X instead", say that.
  - Say when you do not know, or when the answer depends on something that is \
  not in the document. That is more useful than a confident guess.
  - Do not restate the annotation back before answering it.

  You cannot change the document from here and nothing you write will be \
  applied. Somebody reads this and decides. So argue the case; do not announce \
  an edit as though you were about to make one.

  Reply with the text of your answer alone. Markdown is fine. No preamble, no \
  sign-off, no "here is my reply".
  """

  @doc """
  Asks a model to answer one annotation.
  """
  @impl Behaviour
  @spec respond(input(), [opt()]) :: {:ok, String.t()} | {:error, error()}
  def respond(input, opts \\ []) do
    opts =
      opts
      |> Keyword.put_new(:name, "annotation")
      |> Keyword.put_new(:idle_timeout, idle_timeout())

    case Print.run(@prompt, JSON.encode!(input), opts) do
      {:ok, text} -> {:ok, String.trim(text)}
      {:error, _reason} = error -> error
    end
  end

  defp idle_timeout do
    :rinto_pmo
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:idle_timeout, 180_000)
  end
end
