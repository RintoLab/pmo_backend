defmodule RintoPMO.Conversations do
  @moduledoc """
  The context for conversations: the *process* layer of collaborative review.

  ## Why this exists separately from annotations

  `RintoPMO.Annotations` carries conclusions -- low frequency, read by humans,
  and permanently attached to a document. Review also produces a great deal of
  reasoning, probing and clarification, which is high frequency and read mostly
  by the model. Putting both in one table drowns the annotation thread in chat
  transcript; keeping only the annotations throws away the reasoning, and
  `RintoPMO.Agent.PiSession` cannot hold it either -- it is a `:temporary` OS
  process started with `--no-session`, so pi stores no history of its own.

  ## What is stored

  Turns, not frames. A message is written once, complete, and holds the raw
  text plus the refs that accompanied it -- never the expanded prelude. See
  `RintoPMO.Conversations.Message` and `RintoPMO.Conversations.MessageRef` for
  why each of those is the way it is.

  Nothing here is editable. A conversation is a record of what happened, so
  there is no message update and no message delete; conversations themselves
  are kept permanently, since they are the only thing that can answer "why was
  this paragraph changed to say that", and the only basis for reviving a cold
  topic.
  """

  use RintoPMO, :context

  alias RintoPMO.Conversations.Behaviour
  alias RintoPMO.Conversations.Conversation
  alias RintoPMO.Conversations.Message
  alias RintoPMO.Conversations.MessageRef
  alias RintoPMO.Utils

  @behaviour Behaviour

  @doc """
  Lists conversations, most recently created first.
  """
  @impl true
  def list_conversations(filter) when is_map(filter) do
    Conversation
    |> filter_conversations(filter)
    |> order_by([conversation], desc: conversation.id)
    |> Repo.all()
  end

  @doc """
  Fetches one conversation. Messages are not preloaded; a topic can be long.
  """
  @impl true
  def get_conversation!(id), do: Repo.get!(Conversation, id)

  @doc """
  Starts a topic. It is created cold: no pi process is implied.
  """
  @impl true
  def create_conversation(attrs) do
    attrs
    |> Conversation.changeset()
    |> Repo.insert()
  end

  @doc """
  Renames a topic. Only the title is mutable.
  """
  @impl true
  def update_conversation(%Conversation{} = conversation, attrs) do
    conversation
    |> Conversation.update_changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Lists a conversation's messages in order, oldest first, with their refs.

  `opts` accepts `:after_position` and `:limit` for forward paging.
  """
  @impl true
  def list_messages(%Conversation{} = conversation, opts) when is_map(opts) do
    conversation
    |> Ecto.assoc(:messages)
    |> then(fn query ->
      case Map.fetch(opts, :after_position) do
        {:ok, position} -> where(query, [message], message.position > ^position)
        :error -> query
      end
    end)
    |> then(fn query ->
      case Map.fetch(opts, :limit) do
        {:ok, limit} -> limit(query, ^limit)
        :error -> query
      end
    end)
    |> order_by([message], asc: message.position)
    |> Repo.all()
    |> Repo.preload(:refs)
  end

  @doc """
  The last `limit` messages, still oldest first.

  This is what a replay is built from. Replaying an entire topic is expensive
  and rarely more useful than its tail, so reviving a cold conversation
  re-establishes only the recent turns and re-expands their refs.
  """
  @impl true
  def recent_messages(%Conversation{} = conversation, limit)
      when is_integer(limit) and limit > 0 do
    conversation
    |> Ecto.assoc(:messages)
    |> order_by([message], desc: message.position)
    |> limit(^limit)
    |> Repo.all()
    |> Enum.reverse()
    |> Repo.preload(:refs)
  end

  @doc """
  Fetches one message scoped to its conversation, with refs.
  """
  @impl true
  def get_message!(%Conversation{} = conversation, id) do
    conversation
    |> Ecto.assoc(:messages)
    |> where([message], message.id == ^id)
    |> Repo.one!()
    |> Repo.preload(:refs)
  end

  @doc """
  Appends a message with the next monotonic position, together with its refs.

  `attrs` takes `actor_id`, `role`, `content` and an optional `refs` list of
  the raw ref maps the client sent. Each is stored verbatim as `payload` and
  additionally normalised into indexed columns.
  """
  @impl true
  def append_message(%Conversation{} = conversation, attrs) do
    refs = ref_maps(attrs)

    Repo.transact(fn repo ->
      # Locking the conversation rather than computing max() optimistically:
      # two browser tabs on the same topic would otherwise race to the same
      # position and one insert would lose to the unique index.
      locked =
        Conversation
        |> where([candidate], candidate.id == ^conversation.id)
        |> lock("FOR UPDATE")
        |> repo.one!()

      position = next_message_position(repo, locked.id)

      attrs =
        attrs
        |> drop_keys(["refs", "conversation_id", "position"])
        |> Map.merge(%{conversation_id: locked.id, position: position})

      with {:ok, message} <- attrs |> Message.changeset() |> repo.insert(),
           {:ok, stored_refs} <- insert_refs(repo, message, refs) do
        {:ok, %{message | refs: stored_refs}}
      end
    end)
  end

  @doc """
  Marks a conversation hot by recording the pi session carrying it.
  """
  @impl true
  def attach_session(%Conversation{} = conversation, pi_session_id)
      when is_binary(pi_session_id) do
    conversation
    |> Conversation.session_changeset(pi_session_id)
    |> Repo.update()
  end

  @doc """
  Marks a conversation cold. The messages stay; only the process pointer goes.
  """
  @impl true
  def detach_session(%Conversation{} = conversation) do
    conversation
    |> Conversation.session_changeset(nil)
    |> Repo.update()
  end

  @doc """
  Finds the conversation a pi session is carrying, if any.
  """
  @impl true
  def get_conversation_by_session(pi_session_id) when is_binary(pi_session_id) do
    Repo.get_by(Conversation, pi_session_id: pi_session_id)
  end

  @doc """
  Lists the conversations that ever put a given thing in front of the model.

  This is the derived many-to-many the design leans on instead of a join
  table: "which topics discussed this annotation?" is answered from
  `message_refs`, using its `(ref_type, ref_id)` index.
  """
  @impl true
  def list_conversations_for_ref(ref_type, ref_id) when is_binary(ref_type) do
    Conversation
    |> join(:inner, [conversation], message in assoc(conversation, :messages))
    |> join(:inner, [_conversation, message], ref in assoc(message, :refs))
    |> where([_conversation, _message, ref], ref.ref_type == ^ref_type and ref.ref_id == ^ref_id)
    |> distinct(true)
    |> order_by([conversation], desc: conversation.id)
    |> Repo.all()
  end

  # Refs

  defp ref_maps(attrs) do
    case Map.get(attrs, :refs) || Map.get(attrs, "refs") do
      refs when is_list(refs) -> refs
      _absent -> []
    end
  end

  defp insert_refs(_repo, _message, []), do: {:ok, []}

  defp insert_refs(repo, message, refs) do
    refs
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {ref, position}, {:ok, acc} ->
      attrs =
        ref
        |> normalize_ref()
        |> Map.merge(%{message_id: message.id, position: position})

      case attrs |> MessageRef.changeset() |> repo.insert() do
        {:ok, stored} -> {:cont, {:ok, [stored | acc]}}
        {:error, changeset} -> {:halt, {:error, changeset}}
      end
    end)
    |> case do
      {:ok, stored} -> {:ok, Enum.reverse(stored)}
      error -> error
    end
  end

  # The normalised columns are best-effort by design. A ref that fails to
  # normalise -- an unknown type, a slug whose project has since been renamed
  # -- still gets stored, because `payload` is what replay needs and dropping
  # the message would lose the turn over a broken index entry.
  defp normalize_ref(%{"type" => "annotation", "id" => id, "document_id" => document_id} = ref) do
    %{
      ref_type: "annotation",
      ref_id: cast_id(id),
      ref_document_id: cast_id(document_id),
      payload: ref
    }
  end

  defp normalize_ref(%{"type" => "project", "slug" => slug} = ref) when is_binary(slug) do
    %{ref_type: "project", ref_id: project_id(slug), payload: ref}
  end

  defp normalize_ref(%{"type" => type, "id" => id} = ref) when is_binary(type) do
    %{ref_type: type, ref_id: cast_id(id), payload: ref}
  end

  defp normalize_ref(%{"type" => type} = ref) when is_binary(type) do
    %{ref_type: type, payload: ref}
  end

  defp normalize_ref(ref) when is_map(ref), do: %{ref_type: "unknown", payload: ref}

  # A project ref is keyed by slug, so the indexed id has to be looked up at
  # write time. `payload` keeps the slug either way, so a miss costs the
  # reverse lookup for that ref and nothing else.
  defp project_id(slug) do
    Utils.module(:projects).get_project_by_slug!(slug).id
  rescue
    Ecto.NoResultsError -> nil
  end

  defp cast_id(id) when is_binary(id) do
    case UUIDv7.cast(id) do
      {:ok, cast} -> cast
      :error -> nil
    end
  end

  defp cast_id(_id), do: nil

  # Helpers

  defp filter_conversations(query, filter) do
    Enum.reduce(filter, query, fn
      {:actor_id, actor_id}, query ->
        where(query, [conversation], conversation.actor_id == ^actor_id)

      {_other, _value}, query ->
        query
    end)
  end

  defp next_message_position(repo, conversation_id) do
    Message
    |> where([message], message.conversation_id == ^conversation_id)
    |> select([message], max(message.position))
    |> repo.one()
    |> case do
      nil -> 0
      max_position -> max_position + 1
    end
  end

  defp drop_keys(attrs, keys) do
    Map.drop(attrs, keys ++ Enum.map(keys, &String.to_existing_atom/1))
  end
end
