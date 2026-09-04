defmodule RintoPMO.Annotations do
  @moduledoc """
  The context for document annotations and flat follow-up replies.

  ## Nothing here decides anything

  An annotation is somebody pointing at a paragraph and saying it is wrong. It
  ends when a person says it has ended -- `confirm_annotation/2` -- and there is
  no state in between that the system works out on its own. There used to be
  one: a filter that answered "the AI has replied and it is now your turn",
  derived from where a reply had come from. It is gone, and its absence is the
  design rather than a gap. What a person has not looked at is not something
  this module is in a position to know.

  ## The AI writes here through the same door a person does

  There is one write path and everything uses it. A model answering a note or
  reviewing a document is a topic running `rinto-pmo doc annotation`, which is
  an API call into `create_annotation/2` and `create_reply/2` -- so what it
  writes is positioned, indexed and reference-checked exactly like anybody
  else's, and a dead `rinto://` link earns it the same refusal.

  There used to be two more doors: `request_reply/1` and `request_review/1`,
  each a background job calling a model configured by a system-wide role. Both
  are gone. They were one person clicking one button about one thing, which is
  a conversation with the asking hidden -- and hiding it cost the ability to
  say "again, but shorter". See `docs/implementation-plan-prompt-shortcuts.md`.

  What survives that removal is the boundary itself. Nothing has to work out
  whether a discussion has concluded, because somebody asking *is* the
  boundary.
  """

  use RintoPMO, :context

  alias RintoPMO.Annotations.Annotation
  alias RintoPMO.Annotations.AnnotationReply
  alias RintoPMO.Documents.Document
  alias RintoPMO.Links
  alias RintoPMO.References.Guard
  alias RintoPMO.Utils

  defmodule Behaviour do
    @moduledoc false

    alias RintoPMO.Annotations.Annotation
    alias RintoPMO.Annotations.AnnotationReply
    alias RintoPMO.Documents.Document

    @type filter :: %{
            optional(:block_id) => UUIDv7.t() | nil,
            optional(:confirmed) => boolean()
          }

    @callback list_annotations(Document.t(), filter()) :: [Annotation.t()]
    @callback get_annotation!(Document.t(), UUIDv7.t()) :: Annotation.t()
    @callback create_annotation(Document.t(), map()) ::
                {:ok, Annotation.t()} | {:error, Ecto.Changeset.t()}
    @callback update_annotation(Annotation.t(), map()) ::
                {:ok, Annotation.t()} | {:error, Ecto.Changeset.t()}
    @callback delete_annotation(Annotation.t()) ::
                {:ok, Annotation.t()} | {:error, Ecto.Changeset.t()}

    @callback confirm_annotation(Annotation.t(), map()) ::
                {:ok, Annotation.t()} | {:error, Ecto.Changeset.t()}
    @callback unconfirm_annotation(Annotation.t()) ::
                {:ok, Annotation.t()} | {:error, Ecto.Changeset.t()}

    @callback create_reply(Annotation.t(), map()) ::
                {:ok, AnnotationReply.t()} | {:error, Ecto.Changeset.t()}
    @callback update_reply(AnnotationReply.t(), map()) ::
                {:ok, AnnotationReply.t()} | {:error, Ecto.Changeset.t()}
    @callback delete_reply(AnnotationReply.t()) ::
                {:ok, AnnotationReply.t()} | {:error, Ecto.Changeset.t()}
    @callback get_reply!(Annotation.t(), UUIDv7.t()) :: AnnotationReply.t()
  end

  @behaviour Behaviour

  @doc """
  Lists annotations for a document without preloading replies.

  Newest annotations first.
  """
  @impl true
  def list_annotations(%Document{} = document, filter) when is_map(filter) do
    document
    |> Ecto.assoc(:annotations)
    |> filter_annotations(filter)
    |> order_by([annotation], desc: annotation.id)
    |> Repo.all()
  end

  @doc """
  Fetches one annotation scoped to a document, with replies ordered by position.
  """
  @impl true
  def get_annotation!(%Document{} = document, id) do
    document
    |> Ecto.assoc(:annotations)
    |> where([annotation], annotation.id == ^id)
    |> Repo.one!()
    |> Repo.preload(:replies)
  end

  @doc """
  Creates an annotation on a document. Replies start empty.

  ## Who it is by

  `conversation_id` decides, the same fork `create_reply/2` makes: sent, the
  note is a model's and is signed by the stand-in AI; absent, it is the
  caller's own.

  ## Where it lands

  A `block_id` is resolved against the document's current blocks. Found, the
  block's text is snapshotted alongside it if the caller did not supply one --
  the snapshot is what lets the note still say which paragraph it was about
  after that paragraph is rewritten. Not found, the note is written
  **unanchored** rather than refused: the text still names what it is about,
  and an opinion with no pin in the margin is a shape this system already has.

  That degradation matters most for a model, which can name a block that never
  existed or one that has gone since it read the document. It is not restricted
  to models, because a dangling anchor is nobody's idea of a good outcome.
  """
  @impl true
  def create_annotation(%Document{} = document, attrs) do
    with :ok <- Guard.check(content_of(attrs)),
         {:ok, attrs} <- put_author(attrs) do
      attrs = anchor(attrs, document, attr(attrs, :block_id, nil))

      Repo.transact(fn repo ->
        %Annotation{document_id: document.id}
        |> Annotation.changeset(attrs)
        |> repo.insert()
        |> index(repo)
      end)
    end
  end

  @doc """
  Updates annotation content or anchor snapshots.
  """
  @impl true
  def update_annotation(%Annotation{} = annotation, attrs) do
    with :ok <- Guard.check(content_of(attrs)) do
      Repo.transact(fn repo ->
        annotation
        |> Annotation.update_changeset(attrs)
        |> repo.update()
        |> index(repo)
      end)
    end
  end

  @doc """
  Deletes an annotation and its replies.
  """
  @impl true
  def delete_annotation(%Annotation{} = annotation) do
    Repo.transact(fn repo ->
      # Before the delete, not after: the database cascades the replies away,
      # and their index rows have to be read out while they still exist.
      Links.purge_annotation(repo, annotation)
      repo.delete(annotation)
    end)
  end

  @doc """
  Marks a thread over, optionally naming the change that settled it.

  `attrs` may carry `confirmed_by_revision_id`. Present means a change to the
  document answered this; absent means somebody looked and decided none was
  needed. Both are confirmations, which is why there is one verb and not two --
  the difference is already in the pointer, and a second state name would say
  it again.

  Never travels through `update_annotation/2`, so that editing wording cannot
  close a thread. Confirming twice leaves the original moment alone.
  """
  @impl true
  def confirm_annotation(%Annotation{} = annotation, attrs) do
    annotation
    |> Annotation.confirm_changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Takes the mark off, so the thread is open again.

  Clears the revision pointer with it: whatever settled this no longer does,
  and a pointer left behind would be a claim about a decision that has been
  taken back.

  Deleting is a different thing and stays a different thing -- it takes the
  replies with it and leaves the topics that cited this annotation pointing at
  nothing. This is for a decision somebody wants to make again.
  """
  @impl true
  def unconfirm_annotation(%Annotation{} = annotation) do
    annotation
    |> Annotation.unconfirm_changeset()
    |> Repo.update()
  end

  @doc """
  Appends a reply with the next monotonic position.

  ## Who it is by

  `conversation_id` decides. Sent, the reply is a model's and is signed by the
  stand-in AI; absent, it is the caller's own and keeps the `actor_id` the
  token put there. The same fork `RintoPMO.Documents.create_document/1` makes,
  and for the same reason: what a signature answers is model-or-person, and
  only the caller knows which it is about to be.

  **The topic is not looked up.** Creating a document reads it, because a
  document *records* which topic produced it and a wrong id would be written
  down. Nothing here is stored -- since signing stopped depending on which
  assistant a topic was configured with, `conversation_id` says only "a model
  is writing this", and checking that the topic exists would not make that
  claim any truer.
  """
  @impl true
  def create_reply(%Annotation{} = annotation, attrs) do
    with :ok <- Guard.check(content_of(attrs)),
         {:ok, attrs} <- put_author(attrs) do
      Repo.transact(fn repo ->
        locked =
          Annotation
          |> where([candidate], candidate.id == ^annotation.id)
          |> lock("FOR UPDATE")
          |> repo.one!()

        position = next_reply_position(repo, locked.id)

        %AnnotationReply{annotation_id: locked.id, position: position}
        |> AnnotationReply.changeset(attrs)
        |> repo.insert()
        |> index_reply(repo)
      end)
    end
  end

  defp put_author(attrs) do
    case attr(attrs, :conversation_id, nil) do
      conversation_id when is_binary(conversation_id) ->
        case Utils.module(:actors).get_default_assistant() do
          # Flat, unlike `RintoPMO.Documents`: that context wraps and unwraps on
          # the way out, and this one hands the fallback controller its errors
          # as they are.
          nil -> {:error, :default_assistant_missing, %{conversation_id: conversation_id}}
          actor -> {:ok, put_attr(attrs, :actor_id, actor.id)}
        end

      _absent ->
        {:ok, attrs}
    end
  end

  # Both key shapes, because a controller hands this string keys and everything
  # inside hands it atoms.
  defp attr(attrs, key, default) do
    cond do
      Map.has_key?(attrs, key) -> Map.get(attrs, key)
      Map.has_key?(attrs, Atom.to_string(key)) -> Map.get(attrs, Atom.to_string(key))
      true -> default
    end
  end

  # Written back in whichever style the map is already in. Mixing them is not a
  # near miss -- `Ecto.Changeset.cast/3` refuses a map carrying both.
  defp put_attr(attrs, key, value) do
    if Enum.any?(Map.keys(attrs), &is_atom/1) do
      Map.put(attrs, key, value)
    else
      Map.put(attrs, Atom.to_string(key), value)
    end
  end

  @doc """
  Updates a reply's content. Position is immutable.
  """
  @impl true
  def update_reply(%AnnotationReply{} = reply, attrs) do
    with :ok <- Guard.check(content_of(attrs)) do
      Repo.transact(fn repo ->
        reply
        |> AnnotationReply.update_changeset(attrs)
        |> repo.update()
        |> index_reply(repo)
      end)
    end
  end

  @doc """
  Deletes a reply without renumbering later positions.
  """
  @impl true
  def delete_reply(%AnnotationReply{} = reply) do
    Repo.transact(fn repo ->
      with {:ok, deleted} <- repo.delete(reply) do
        # After the delete, not before: the annotation is re-projected as its
        # own text plus its replies, and this one must already be gone from it.
        Links.purge(repo, "annotation_reply", reply.id)
        {:ok, deleted}
      end
    end)
  end

  @doc """
  Fetches a reply scoped to an annotation.
  """
  @impl true
  def get_reply!(%Annotation{} = annotation, id) do
    annotation
    |> Ecto.assoc(:replies)
    |> where([reply], reply.id == ^id)
    |> Repo.one!()
  end

  # In the same transaction as the write, so that the body and "who points at
  # this?" never disagree, not even briefly. See `RintoPMO.Links`.
  defp index({:ok, %Annotation{} = annotation}, repo) do
    Links.sync_annotation(repo, annotation)
    {:ok, annotation}
  end

  defp index(result, _repo), do: result

  defp index_reply({:ok, %AnnotationReply{} = reply}, repo) do
    Links.sync_reply(repo, reply)
    {:ok, reply}
  end

  defp index_reply(result, _repo), do: result

  defp content_of(attrs), do: Map.get(attrs, :content) || Map.get(attrs, "content")

  # A block id the model invented, or one that has gone since it read the
  # document, leaves the note unanchored rather than throwing it away. The text
  # still names what it is about, and an opinion with no pin in the margin is
  # the shape this system already has for one about the whole document.
  defp anchor(attrs, %Document{} = document, block_id) when is_binary(block_id) do
    case blocks_of(document) do
      # Nobody looked. A caller holding a document whose blocks were never
      # loaded has told us nothing about whether this anchor is good, and
      # treating silence as "the block is gone" would drop anchors that are
      # perfectly fine. Every path that cares loads them --
      # `RintoPMO.Documents.get_document!/1` preloads the latest revision's
      # blocks, and the controller every write comes through goes through it.
      :unloaded -> attrs
      blocks -> place_on(attrs, blocks, block_id)
    end
  end

  defp anchor(attrs, _document, _block_id), do: attrs

  defp place_on(attrs, blocks, block_id) do
    case Enum.find(blocks, &(&1.block_id == block_id)) do
      # Dropped rather than kept: an id pointing at no block anchors the note to
      # nothing while claiming otherwise, and every reader of `block_id` would
      # have to defend against it.
      nil ->
        attrs |> drop_attr(:block_id) |> drop_attr(:block_text)

      block ->
        attrs
        |> put_attr(:block_id, block.block_id)
        |> snapshot(block)
    end
  end

  # Filled, never overwritten. A client that captured the text as somebody
  # highlighted a phrase holds the snapshot that matches its `selected_text`;
  # replacing it with what the block says now would leave the two describing
  # different revisions.
  defp snapshot(attrs, block) do
    if attr(attrs, :block_text, nil),
      do: attrs,
      else: put_attr(attrs, :block_text, block.content)
  end

  defp blocks_of(%Document{latest_revision: %{blocks: blocks}}) when is_list(blocks), do: blocks
  defp blocks_of(_not_loaded), do: :unloaded

  defp drop_attr(attrs, key), do: Map.drop(attrs, [key, Atom.to_string(key)])

  defp filter_annotations(query, filter) do
    Enum.reduce(filter, query, fn
      {:block_id, nil}, query ->
        where(query, [annotation], is_nil(annotation.block_id))

      {:block_id, block_id}, query ->
        where(query, [annotation], annotation.block_id == ^block_id)

      {:confirmed, true}, query ->
        where(query, [annotation], not is_nil(annotation.confirmed_at))

      {:confirmed, false}, query ->
        where(query, [annotation], is_nil(annotation.confirmed_at))

      {_other, _value}, query ->
        query
    end)
  end

  defp next_reply_position(repo, annotation_id) do
    AnnotationReply
    |> where([reply], reply.annotation_id == ^annotation_id)
    |> select([reply], max(reply.position))
    |> repo.one()
    |> case do
      nil -> 0
      max_position -> max_position + 1
    end
  end
end
