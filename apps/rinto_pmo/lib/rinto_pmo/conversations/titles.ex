defmodule RintoPMO.Conversations.Titles do
  @moduledoc """
  Names a topic from the first thing said in it.

  ## Why naming happens once, and late

  A topic is created before anyone has said anything, so there is nothing to
  name it after: the frontend opens a conversation the moment a panel opens.
  Naming it then would produce "新话题 3". Naming it from the first user
  message is the earliest moment the name can be true, and by then the person
  has already moved on to waiting for an answer -- which is why this runs in
  the background and why a failure here is never allowed to reach them.

  Only the first message is used. Re-summarising as a conversation grows would
  make the list move under the reader: a topic they named in their head as "上
  线流程" becomes "回滚脚本" while they are reading it. The name is where the
  topic started, and starting points do not change.

  ## What may be overwritten: nothing anyone chose

  Every write goes through `apply_title/2`, a single conditional UPDATE that
  requires the row to still be unnamed *and* unclaimed. That is what makes all
  of this safe to retry, to run twice, and to race with a person renaming the
  topic in another tab: the last state a person asked for is the one that
  survives, no matter which finished last. See
  `RintoPMO.Conversations.Conversation` for what the two columns mean together.

  ## What the model is told

  The first user message and a label per reference -- never a document's
  contents. `RintoPMO.Agent.PromptBuilder` expands references for a
  conversation because the model has to reason about them; naming needs only
  enough to tell one topic from another, and expanding here would spend a large
  request on a short string.

  A model is not required. `fallback/1` builds a title out of the message
  itself, and it is used whenever the model is slow, missing, unconfigured or
  returns something unusable. A topic always ends up named.
  """

  use RintoPMO, :context

  alias RintoPMO.Actors.Actor
  alias RintoPMO.Agent.TitleGenerator
  alias RintoPMO.Conversations.Conversation
  alias RintoPMO.Conversations.Message
  alias RintoPMO.Conversations.Notifier
  alias RintoPMO.Conversations.TitleWorker
  alias RintoPMO.Documents.Document
  alias RintoPMO.Documents.DocumentRevision
  alias RintoPMO.Settings
  alias RintoPMO.Utils

  require Logger

  @typedoc "How the title that was written came about."
  @type source :: :model | :fallback

  # A title is a phrase, and the rest of a long message says nothing more about
  # what the topic is. Cutting here keeps a pasted document out of the request.
  @default_message_chars 2_000
  @default_summary_chars 120

  # Chinese says in a dozen characters what English needs sixty for, so one
  # limit would either truncate the first or wave through a sentence of the
  # second.
  @cjk_graphemes 24
  @latin_graphemes 60

  # Below this a message is a gesture rather than a subject ("帮我看看这个"),
  # and whatever it points at is the better name.
  @gesture_graphemes 8

  @doc """
  Queues naming for a conversation, if it is still unnamed.

  Called for every appended user message, so the check happens here rather than
  at each call site. The row is re-read: the caller's copy may predate a rename
  that has already happened.
  """
  @spec enqueue(UUIDv7.t()) :: {:ok, Oban.Job.t()} | :ignore
  def enqueue(conversation_id) when is_binary(conversation_id) do
    if enabled?() and unnamed?(conversation_id) do
      %{conversation_id: conversation_id}
      |> TitleWorker.new()
      |> Oban.insert()
      |> case do
        {:ok, job} ->
          {:ok, job}

        {:error, reason} ->
          # The conversation is worth more than its name. A queue that will not
          # take the job leaves the topic unnamed, and `mix
          # rinto.conversations.backfill_titles` exists for exactly that.
          Logger.warning(
            "conversation #{conversation_id}: title job not queued, #{inspect(reason)}"
          )

          :ignore
      end
    else
      :ignore
    end
  end

  @doc """
  Names a conversation now: asks a model, falls back, writes conditionally.

  Returns `{:ok, conversation, source}` when this call is the one that named
  it, `:stale` when the row stopped being eligible while the model was
  answering, and `:ignore` when there was nothing to name -- no such
  conversation, no user message yet, or a name already.

  Never raises on a model failure. There is a human waiting on an answer that
  has nothing to do with this.
  """
  @spec name(UUIDv7.t() | Conversation.t()) ::
          {:ok, Conversation.t(), source()} | :stale | :ignore
  def name(%Conversation{} = conversation), do: name(conversation.id)

  def name(conversation_id) when is_binary(conversation_id) do
    with {:ok, conversation} <- fetch_eligible(conversation_id),
         {:ok, message} <- first_user_message(conversation) do
      {title, source} = title_for(conversation, message)
      write(conversation, title, source)
    else
      :ignore -> :ignore
    end
  end

  @doc """
  Writes a title only while the topic is still unnamed and unclaimed.

  A conditional UPDATE rather than a read followed by a write: between the two
  a person can rename the topic, and this would put the model's guess back over
  their choice. Nothing about a title is worth taking a decision away from
  somebody.
  """
  @spec apply_title(UUIDv7.t(), String.t()) :: {:ok, Conversation.t()} | :stale
  def apply_title(conversation_id, title) when is_binary(title) do
    query =
      Conversation
      |> where([conversation], conversation.id == ^conversation_id)
      |> where([conversation], is_nil(conversation.title) and is_nil(conversation.title_source))
      |> select([conversation], conversation)

    # `updated_at` is left alone on purpose: the conversation list is ordered by
    # it, and a title arriving must not shuffle a three-week-old topic to the
    # top of somebody's list.
    #
    # `embedding` is cleared by hand here because this path does not go through
    # a changeset, so `RintoPMO.Embeddings.invalidate/2` never sees it. A topic
    # whose title arrives is a topic whose findable text just changed.
    case Repo.update_all(query,
           set: [
             title: title,
             title_source: :auto,
             title_generated_at: DateTime.utc_now(),
             embedding: nil
           ]
         ) do
      {1, [conversation]} -> {:ok, conversation}
      {0, _none} -> :stale
    end
  end

  @doc """
  The ids of topics that are unnamed and have something to be named after.

  Oldest first, so a backfill run twice over gets through the same rows in the
  same order. Empty topics are not listed: an empty topic is unnamed because
  there is nothing to say about it, not because anything went wrong.
  """
  @spec pending(pos_integer() | nil) :: [UUIDv7.t()]
  def pending(limit \\ nil) do
    said_something =
      from message in Message,
        where: parent_as(:conversation).id == message.conversation_id and message.role == :user,
        select: 1

    from(conversation in Conversation, as: :conversation)
    |> where([conversation], is_nil(conversation.title) and is_nil(conversation.title_source))
    |> where(exists(subquery(said_something)))
    |> order_by([conversation], asc: conversation.id)
    |> then(fn query -> if limit, do: limit(query, ^limit), else: query end)
    |> select([conversation], conversation.id)
    |> Repo.all()
  end

  @doc """
  Whether a conversation may still be named automatically.
  """
  @spec eligible?(Conversation.t()) :: boolean()
  def eligible?(%Conversation{title: nil, title_source: nil}), do: true
  def eligible?(%Conversation{}), do: false

  @doc """
  The earliest user turn in a conversation, with its references.

  An empty topic has none, and an empty topic stays unnamed.
  """
  @spec first_user_message(Conversation.t()) :: {:ok, Message.t()} | :ignore
  def first_user_message(%Conversation{} = conversation) do
    conversation
    |> Ecto.assoc(:messages)
    |> where([message], message.role == :user)
    |> order_by([message], asc: message.position)
    |> limit(1)
    |> Repo.one()
    |> case do
      nil -> :ignore
      message -> {:ok, Repo.preload(message, :refs)}
    end
  end

  @doc """
  What the model is given: the message, labels for its references, a locale.
  """
  @spec input_for(Message.t()) :: TitleGenerator.input()
  def input_for(%Message{} = message) do
    content = clamp(message.content, message_chars())

    %{
      first_user_message: content,
      references: Enum.map(message.refs, &summarise_ref/1),
      locale: locale(content)
    }
  end

  @doc """
  A title built from the message alone, for when there is no usable model one.

  A gesture of a message ("帮我看看这个") says nothing on its own, so what it
  pointed at is used instead -- that reference is the subject the person had in
  front of them.
  """
  @spec fallback(Message.t()) :: String.t()
  def fallback(%Message{} = message) do
    plain = message.content |> strip_markup() |> collapse_whitespace() |> first_sentence()
    reference = message.refs |> Enum.map(&label/1) |> Enum.find(&is_binary/1)

    cond do
      substantial?(plain) -> truncate(plain)
      is_binary(reference) -> truncate(reference)
      plain != "" -> truncate(plain)
      is_binary(message.content) -> truncate(collapse_whitespace(message.content))
      true -> ""
    end
  end

  @doc """
  Cleans a model's answer into something that can be a title.

  The instructions ask for a bare title; models answer with headings, quotes,
  "标题：" and the occasional paragraph of reasoning anyway. Returns `:error`
  when nothing usable is left, which is the fallback's cue.
  """
  @spec sanitise(String.t() | term()) :: {:ok, String.t()} | :error
  def sanitise(text) when is_binary(text) do
    text
    |> first_line()
    |> unwrap()
    |> collapse_whitespace()
    |> truncate()
    |> case do
      "" -> :error
      title -> {:ok, title}
    end
  end

  def sanitise(_other), do: :error

  # Naming

  defp title_for(conversation, message) do
    started = System.monotonic_time(:millisecond)

    case generate(conversation, message) do
      {:ok, title} ->
        measure(conversation, :model, started, nil)
        {title, :model}

      {:error, reason} ->
        measure(conversation, :fallback, started, reason)
        {fallback(message), :fallback}
    end
  end

  defp generate(conversation, message) do
    ask(input_for(message), generator_opts(conversation))
  end

  # Only the call itself is guarded, so that a mistake on this side still
  # surfaces as a failed job rather than as a quietly worse title.
  defp ask(input, opts) do
    with {:ok, raw} <- generator().generate(input, opts) do
      case sanitise(raw) do
        {:ok, title} -> {:ok, title}
        # Answered, but with nothing a title can be made of. Indistinguishable
        # from a failure as far as what happens next.
        :error -> {:error, :unusable_output}
      end
    end
  rescue
    # A generator that raises is a generator that failed, and the fallback
    # handles that. Letting it through would retry the job, ask the same broken
    # provider again, and leave the topic unnamed in the meantime.
    error -> {:error, {:raised, Exception.message(error)}}
  end

  defp write(_conversation, "", _source), do: :ignore

  defp write(conversation, title, source) do
    case apply_title(conversation.id, title) do
      {:ok, named} ->
        Notifier.broadcast_updated(named)
        {:ok, named, source}

      :stale ->
        # Somebody named it while the model was thinking, or another job got
        # there first. Both are the system working.
        :telemetry.execute([:rinto_pmo, :conversation_title, :stale], %{count: 1}, %{
          conversation_id: conversation.id
        })

        :stale
    end
  end

  # Whoever was chosen to name topics, and the topic's own assistant when
  # nobody was. The chosen one wins because naming is a fixed, tiny job that
  # somebody picked a cheap model for; the assistant is the fallback because it
  # is configured, its credentials work, and it is what the person is already
  # talking to.
  defp generator_opts(conversation) do
    case Settings.get_actor("title_actor") || assistant(conversation) do
      %Actor{} = actor ->
        [provider: actor.provider, model: actor.model, thinking: actor.thinking_level]

      nil ->
        []
    end
  end

  defp assistant(%Conversation{assistant_actor_id: nil}), do: nil

  defp assistant(%Conversation{assistant_actor_id: actor_id}) do
    Utils.module(:actors).get_actor!(actor_id)
  rescue
    Ecto.NoResultsError -> nil
  end

  defp fetch_eligible(conversation_id) do
    case Repo.get(Conversation, conversation_id) do
      %Conversation{} = conversation ->
        if eligible?(conversation), do: {:ok, conversation}, else: :ignore

      nil ->
        :ignore
    end
  end

  defp unnamed?(conversation_id) do
    Conversation
    |> where([conversation], conversation.id == ^conversation_id)
    |> where([conversation], is_nil(conversation.title) and is_nil(conversation.title_source))
    |> Repo.exists?()
  end

  # Observability. The message itself is never logged: a title job runs over
  # whatever somebody typed, and diagnosing the queue does not require reading
  # it.
  defp measure(conversation, outcome, started, reason) do
    duration = System.monotonic_time(:millisecond) - started

    :telemetry.execute(
      [:rinto_pmo, :conversation_title, outcome],
      %{duration: duration},
      %{conversation_id: conversation.id, reason: reason}
    )

    if reason do
      Logger.info(
        "conversation #{conversation.id}: title fell back after #{inspect(reason)} (#{duration}ms)"
      )
    end
  end

  # References

  defp summarise_ref(ref) do
    case label(ref) do
      nil -> %{type: ref.ref_type}
      label -> %{type: ref.ref_type, title: label}
    end
  end

  # Best effort by design: a reference whose target has been deleted since is
  # ordinary, and a title is not worth failing over one. The type alone still
  # tells the model that a document was in front of the person.
  defp label(%{ref_type: "document", ref_id: id}) when is_binary(id) do
    case documents().get_document!(id) do
      %Document{latest_revision: %DocumentRevision{title: title}} -> clamp(title, summary_chars())
      _no_revision -> nil
    end
  rescue
    _missing -> nil
  end

  defp label(%{ref_type: type, ref_document_id: document_id, ref_id: id})
       when type in ["annotation", "proposal"] and is_binary(document_id) and is_binary(id) do
    document = documents().get_document!(document_id)

    case type do
      "annotation" -> clamp(annotations().get_annotation!(document, id).content, summary_chars())
      "proposal" -> clamp(documents().get_proposal!(document, id).content, summary_chars())
    end
  rescue
    _missing -> nil
  end

  defp label(%{ref_type: "project", payload: %{"slug" => slug}}) when is_binary(slug) do
    clamp(projects().get_project_by_slug!(slug).name, summary_chars())
  rescue
    _missing -> nil
  end

  defp label(%{ref_type: "attachment", ref_id: id}) when is_binary(id) do
    clamp(attachments().get_attachment!(id).filename, summary_chars())
  rescue
    _missing -> nil
  end

  defp label(%{payload: %{"title" => title}}) when is_binary(title),
    do: clamp(title, summary_chars())

  defp label(_ref), do: nil

  # Text

  defp first_line(text) do
    text
    |> String.split(["\r\n", "\n"], trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.find("", &(&1 != ""))
  end

  # Heading marks, list bullets, quote pairs, "标题：" and a full stop nest in
  # every combination a model can produce -- `# "Rollback plan".` is all four
  # at once -- so each pass strips one layer and the whole thing repeats until
  # a pass changes nothing.
  defp unwrap(text, passes \\ 5)
  defp unwrap(text, 0), do: text

  defp unwrap(text, passes) do
    stripped =
      text
      |> String.trim()
      |> strip_leading_marks()
      |> strip_prefix()
      |> strip_stop()
      |> strip_quotes()
      |> String.trim()

    if stripped == text, do: stripped, else: unwrap(stripped, passes - 1)
  end

  defp strip_stop(text) do
    text |> String.trim_trailing("。") |> String.trim_trailing(".") |> String.trim()
  end

  defp strip_leading_marks(text), do: String.replace(text, ~r/^\s*(?:\#{1,6}|[-*+•>])\s*/u, "")

  defp strip_prefix(text) do
    String.replace(text, ~r/^\s*(?:标题|主题|题目|Title|Topic|Conversation title)\s*[:：]\s*/iu, "")
  end

  @quote_pairs [{"\"", "\""}, {"'", "'"}, {"“", "”"}, {"‘", "’"}, {"「", "」"}, {"『", "』"}]

  # `《》` is deliberately not here: in Chinese it names a document and belongs
  # in the title.
  defp strip_quotes(text) do
    Enum.reduce(@quote_pairs, text, fn {open, close}, acc ->
      if String.starts_with?(acc, open) and String.ends_with?(acc, close) and
           String.length(acc) > String.length(open <> close) do
        acc
        |> String.replace_prefix(open, "")
        |> String.replace_suffix(close, "")
      else
        acc
      end
    end)
  end

  defp collapse_whitespace(text), do: text |> String.replace(~r/\s+/u, " ") |> String.trim()

  defp strip_markup(text) when is_binary(text) do
    text
    |> String.replace(~r/```.*?```/su, " ")
    |> String.replace(~r/`([^`]*)`/u, "\\1")
    |> String.replace(~r/!?\[([^\]]*)\]\([^)]*\)/u, "\\1")
    |> String.replace(~r/^\s*(?:\#{1,6}|[-*+>]|\d+\.)\s*/mu, "")
    |> String.replace(~r/[*_~]{1,3}/u, "")
  end

  defp strip_markup(_text), do: ""

  # The first sentence is where somebody says what they want; the rest
  # qualifies it. Splitting on both scripts' terminators, and on a line break,
  # which people use as one.
  defp first_sentence(text) do
    text
    |> String.split(~r/(?<=[。！？!?；;])|(?<=[.]\s)/u, parts: 2)
    |> List.first()
    |> to_string()
    |> String.trim()
    |> String.trim_trailing("。")
    |> String.trim_trailing(".")
    |> String.trim()
  end

  defp substantial?(text), do: String.length(text) > @gesture_graphemes

  # Truncation counts graphemes, not bytes: cutting a Chinese title by bytes
  # produces half a character, and cutting by codepoints separates an emoji
  # from its modifier.
  defp truncate(text) do
    limit = if cjk?(text), do: @cjk_graphemes, else: @latin_graphemes

    if String.length(text) <= limit do
      text
    else
      text |> String.slice(0, limit) |> String.trim_trailing()
    end
  end

  defp cjk?(text) do
    graphemes = String.graphemes(text)

    case graphemes do
      [] ->
        false

      _some ->
        han =
          Enum.count(
            graphemes,
            &Regex.match?(
              ~r/[\x{3040}-\x{30FF}\x{3400}-\x{4DBF}\x{4E00}-\x{9FFF}\x{F900}-\x{FAFF}]/u,
              &1
            )
          )

        han * 4 >= length(graphemes)
    end
  end

  defp locale(text), do: if(cjk?(text), do: "zh-CN", else: "en")

  defp clamp(nil, _limit), do: nil

  defp clamp(text, limit) when is_binary(text) do
    text = collapse_whitespace(text)
    if String.length(text) <= limit, do: text, else: String.slice(text, 0, limit) <> "…"
  end

  # Configuration

  defp enabled?, do: setting(:enabled, true)
  defp message_chars, do: setting(:max_message_chars, @default_message_chars)
  defp summary_chars, do: setting(:max_summary_chars, @default_summary_chars)

  defp setting(key, default) do
    :rinto_pmo
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(key, default)
  end

  defp generator, do: Utils.module(:title_generator)
  defp documents, do: Utils.module(:documents)
  defp annotations, do: Utils.module(:annotations)
  defp projects, do: Utils.module(:projects)
  defp attachments, do: Utils.module(:attachments)
end
