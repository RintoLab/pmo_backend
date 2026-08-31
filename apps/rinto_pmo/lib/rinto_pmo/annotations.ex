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

  ## The AI writes here only when asked

  There are two doors and a person opens both. `request_reply/1` answers *this*
  note as the actor holding the `annotation_actor` role; `request_review/1`
  reads whole documents and opens notes as the actor holding `review_actor`.
  They are separate because answering a discussion and reviewing a document
  need different personas and prompts, even though both leave annotations.

  Conversations never write here: a topic produces proposals against the
  document, and that is a different output on a different resource.

  That is what makes the boundary honest. Nothing has to work out whether a
  discussion has concluded, because the asking *is* the boundary: one click,
  one answer.
  """

  use RintoPMO, :context

  alias RintoPMO.Agent.DocumentReviewer
  alias RintoPMO.Annotations.Annotation
  alias RintoPMO.Annotations.AnnotationReply
  alias RintoPMO.Annotations.ReplyWorker
  alias RintoPMO.Annotations.ReviewWorker
  alias RintoPMO.Documents.Document
  alias RintoPMO.Documents.Notifier
  alias RintoPMO.Links
  alias RintoPMO.References.Guard
  alias RintoPMO.Settings
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

    @callback request_reply(Annotation.t()) ::
                {:ok, Oban.Job.t()} | {:error, atom(), map()} | {:error, Ecto.Changeset.t()}
    @callback run_reply(integer(), UUIDv7.t()) :: :ok | {:cancel, String.t()}

    @callback request_review([Document.t()]) ::
                {:ok, Oban.Job.t()} | {:error, atom(), map()} | {:error, Ecto.Changeset.t()}
    @callback run_review(integer(), [UUIDv7.t()]) :: :ok | {:cancel, String.t()}

    @callback create_reply(Annotation.t(), map()) ::
                {:ok, AnnotationReply.t()} | {:error, Ecto.Changeset.t()}
    @callback update_reply(AnnotationReply.t(), map()) ::
                {:ok, AnnotationReply.t()} | {:error, Ecto.Changeset.t()}
    @callback delete_reply(AnnotationReply.t()) ::
                {:ok, AnnotationReply.t()} | {:error, Ecto.Changeset.t()}
    @callback get_reply!(Annotation.t(), UUIDv7.t()) :: AnnotationReply.t()
  end

  @behaviour Behaviour

  # Eight documents is a design and the things it touches, which is the size of
  # question a review is for. It is a ceiling on the request rather than on the
  # model: past it the answer stops being a review of a set and becomes a
  # skim of a library.
  @max_documents 8

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
  """
  @impl true
  def create_annotation(%Document{} = document, attrs) do
    with :ok <- Guard.check(content_of(attrs)) do
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
  Asks the AI for one reply to one annotation.

  The only way anything but a person writes here. A person is looking at a note
  and wants the model's read on it; what comes back is an ordinary reply,
  appended like any other, which somebody can act on, argue with, or ignore.

  Answers with the *job*, before the model has been asked -- the call takes as
  long as it takes, and what a client does next is watch `document:{id}` on the
  socket. `GET /jobs/{id}` is the way back for one that was not listening.

  Refused when nobody holds the `annotation_actor` role. That is a condition of
  asking rather than an outcome of the answer, so it is reported here and
  synchronously, to whoever is making the mistake.

  Asking twice is allowed and appends twice: replies are a list, and a second
  opinion is a second opinion. What it does not do is fire twice for one
  double-click -- while a reply to this annotation is in flight, `Oban` hands
  back the job already queued.

  A confirmed annotation is not refused. Somebody may well want the model's
  read on a decision already taken, and refusing would mean this module had an
  opinion about why they were asking.
  """
  @impl true
  def request_reply(%Annotation{} = annotation) do
    with {:ok, _actor} <- annotation_actor() do
      %{annotation_id: annotation.id}
      |> ReplyWorker.new()
      |> Oban.insert()
    end
  end

  @doc """
  Runs one reply: the model call, the write, and the word to whoever is watching.

  Called by the worker and not by a request. What it leaves behind is the reply
  itself, so the only thing that needs announcing is that it is over -- which
  goes out on the document's own topic either way.

  Answers `:ok`, or `{:cancel, reason}` when the model call failed. `:cancel`
  and not `:error`, for the reason `RintoPMO.Tasks.run_estimation/3` gives:
  this is finished either way, and asking the identical question nineteen more
  times is not a retry policy.
  """
  @impl true
  def run_reply(job_id, annotation_id) do
    case Repo.get(Annotation, annotation_id) do
      # Deleted while the job waited. Nothing to answer, and the note whose
      # thread this would join is not there to hold it.
      nil -> :ok
      annotation -> reply_and_append(job_id, Repo.preload(annotation, :replies))
    end
  end

  @doc """
  Asks the AI to read documents end to end and leave what it finds.

  The other door. `request_reply/1` answers a note somebody already wrote; this
  one opens notes, which is the only thing in this system that writes an
  annotation nobody pointed at a paragraph to make.

  It is still a person's action -- the asking is the boundary, exactly as it is
  for a reply. Nothing decides on its own that a document is due for review.

  ## Why it takes a set

  The findings worth the most are the ones no single document contains: two
  documents that cannot both be true. Reviewing them one at a time and
  comparing afterwards puts the comparison back on whoever asked, which is the
  work they were trying to hand over. So the unit is a selection, and one
  document is a selection of one.

  At most `max_documents/0`. Refused rather than truncated, for the reason
  `too_many_references` is: a caller silently given a smaller review than it
  asked for concludes the rest was clean.

  Duplicates collapse and the list is sorted before it becomes the job's key,
  so the same selection is the same job however it was ordered.

  Refused when nobody holds the `review_actor` role -- a condition of
  asking rather than an outcome of the answer, so it is reported here and
  synchronously.
  """
  @impl true
  def request_review(documents) when is_list(documents) do
    document_ids = documents |> Enum.map(& &1.id) |> Enum.uniq() |> Enum.sort()

    with :ok <- ensure_reviewable(document_ids),
         {:ok, _actor} <- review_actor() do
      %{document_ids: document_ids}
      |> ReviewWorker.new()
      |> Oban.insert()
    end
  end

  @doc """
  The most documents one review may be asked about.
  """
  @spec max_documents() :: pos_integer()
  def max_documents, do: @max_documents

  @doc """
  Runs one review: the model call, the annotations it produces, and the word to
  whoever is watching.

  Called by the worker and not by a request. Every document in the set is told
  about separately, because a client is watching one document's topic and not
  the selection somebody made three tabs ago.

  ## A finding that cannot be placed is dropped, not raised

  Three things can be wrong with what comes back, and each degrades on its own:

    * a `document_id` outside the set -- dropped, because there is nowhere
      honest to put it
    * a `block_id` that is not in that document's latest revision -- written
      unanchored, because the text still names what it is about
    * a note the write path refuses, a dead `rinto://` most likely -- skipped

  None of them takes the other findings down. A model that invents one
  reference should not cost somebody the eleven notes it got right.
  """
  @impl true
  def run_review(job_id, document_ids) when is_list(document_ids) do
    case load_documents(document_ids) do
      # Every one of them deleted while the job waited. Nothing to review and
      # nowhere to say so.
      [] -> :ok
      documents -> review_and_annotate(job_id, documents)
    end
  end

  @doc """
  Appends a reply with the next monotonic position.
  """
  @impl true
  def create_reply(%Annotation{} = annotation, attrs) do
    with :ok <- Guard.check(content_of(attrs)) do
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

  # The model is given the note, what it is anchored to, everything already
  # said under it, and the document as it currently stands. The document is not
  # optional: an annotation says "this contradicts the section above", and an
  # answer written without the section above is a guess about what it meant.
  defp reply_and_append(job_id, %Annotation{} = annotation) do
    with {:ok, actor} <- annotation_actor(),
         {:ok, document} <- fetch_document(annotation),
         {:ok, text} <- call_responder(annotation, document, actor),
         {:ok, _reply} <- append_reply(annotation, actor, text) do
      succeed(job_id, annotation)
    else
      {:error, :no_annotation_actor, _details} ->
        fail(job_id, annotation, "no actor holds the annotation role")

      {:error, %Ecto.Changeset{}} ->
        fail(job_id, annotation, "the model's answer could not be written down")

      {:error, reason} ->
        fail(job_id, annotation, failure_reason(reason))
    end
  end

  defp fetch_document(%Annotation{} = annotation) do
    {:ok, Utils.module(:documents).get_document!(annotation.document_id)}
  rescue
    Ecto.NoResultsError -> {:error, :document_gone}
  end

  defp call_responder(%Annotation{} = annotation, document, actor) do
    input = %{
      annotation: %{
        content: annotation.content,
        block_text: annotation.block_text,
        selected_text: annotation.selected_text,
        replies: Enum.map(annotation.replies, & &1.content)
      },
      document: %{
        title: document.latest_revision.title,
        blocks: Enum.map(document.latest_revision.blocks, & &1.content)
      }
    }

    Utils.module(:annotation_responder).respond(input,
      provider: actor.provider,
      model: actor.model,
      thinking: actor.thinking_level
    )
  end

  # Through `create_reply/2` rather than around it, so the AI's reply is
  # positioned, indexed and reference-checked exactly like a person's. A model
  # that writes a dead `rinto://` link earns the same refusal anybody would.
  defp append_reply(%Annotation{} = annotation, actor, text) do
    create_reply(annotation, %{"actor_id" => actor.id, "content" => text})
  end

  defp annotation_actor do
    case Settings.get_actor("annotation_actor") do
      nil -> {:error, :no_annotation_actor, %{}}
      actor -> {:ok, actor}
    end
  end

  defp review_actor do
    case Settings.get_actor("review_actor") do
      nil -> {:error, :no_review_actor, %{}}
      actor -> {:ok, actor}
    end
  end

  defp ensure_reviewable([]), do: {:error, :no_documents, %{}}

  defp ensure_reviewable(document_ids) when length(document_ids) > @max_documents do
    {:error, :too_many_documents, %{limit: @max_documents}}
  end

  defp ensure_reviewable(_document_ids), do: :ok

  # One at a time, and a missing one is left out rather than failing the batch:
  # a document deleted between the click and the job is not a reason to abandon
  # the review of the others. At most `@max_documents` of them, so the query
  # count is bounded by the same number that bounds the request.
  defp load_documents(document_ids) do
    Enum.flat_map(document_ids, &load_document/1)
  end

  defp load_document(document_id) do
    [Utils.module(:documents).get_document!(document_id)]
  rescue
    Ecto.NoResultsError -> []
  end

  defp review_and_annotate(job_id, documents) do
    with {:ok, actor} <- review_actor(),
         {:ok, findings} <- call_reviewer(documents, actor) do
      succeed_review(job_id, documents, place_and_write(documents, findings, actor))
    else
      {:error, :no_review_actor, _details} ->
        fail_review(job_id, documents, "no actor holds the review role")

      {:error, reason} ->
        fail_review(job_id, documents, failure_reason(reason))
    end
  end

  defp call_reviewer(documents, actor) do
    input = %{documents: Enum.map(documents, &reviewer_document/1)}

    Utils.module(:document_reviewer).review(input,
      provider: actor.provider,
      model: actor.model,
      thinking: actor.thinking_level,
      system_prompt: actor.system_prompt
    )
  end

  # Block ids travel with the text so a finding can name where it belongs. They
  # are ids rather than positions, the way `RintoPMO.Agent.TaskEstimator` hands
  # over task ids: a position means nothing once the answer is read back against
  # a revision that has moved.
  #
  # `block_id` and not the snapshot's primary key -- that is the identity an
  # annotation anchors to, and it is the one that survives the next revision.
  defp reviewer_document(document) do
    %{
      id: document.id,
      title: document.latest_revision.title,
      blocks: Enum.map(document.latest_revision.blocks, &%{id: &1.block_id, text: &1.content})
    }
  end

  # Through `create_annotation/2` rather than around it, so a note the model
  # wrote is positioned, indexed and reference-checked exactly like a person's.
  # A model that writes a dead `rinto://` link earns the same refusal anybody
  # would -- and only that note is lost.
  defp place_and_write(documents, findings, actor) do
    by_id = Map.new(documents, &{&1.id, &1})

    findings
    |> Enum.take(DocumentReviewer.max_findings())
    |> Enum.reduce(%{}, fn finding, written ->
      with {:ok, document, attrs} <- place(finding, by_id),
           {:ok, _annotation} <-
             create_annotation(document, Map.put(attrs, "actor_id", actor.id)) do
        Map.update(written, document.id, 1, &(&1 + 1))
      else
        _unwritable -> written
      end
    end)
  end

  defp place(finding, by_id) when is_map(finding) do
    with content when is_binary(content) <- Map.get(finding, "content"),
         trimmed = String.trim(content),
         false <- trimmed == "",
         %Document{} = document <- Map.get(by_id, Map.get(finding, "document_id")) do
      {:ok, document, anchor(%{"content" => trimmed}, document, Map.get(finding, "block_id"))}
    else
      _unplaceable -> :error
    end
  end

  defp place(_finding, _by_id), do: :error

  # A block id the model invented, or one that has gone since it read the
  # document, leaves the note unanchored rather than throwing it away. The text
  # still names what it is about, and an opinion with no pin in the margin is
  # the shape this system already has for one about the whole document.
  defp anchor(attrs, %Document{} = document, block_id) when is_binary(block_id) do
    case Enum.find(document.latest_revision.blocks, &(&1.block_id == block_id)) do
      nil -> attrs
      block -> Map.merge(attrs, %{"block_id" => block.block_id, "block_text" => block.content})
    end
  end

  defp anchor(attrs, _document, _block_id), do: attrs

  defp succeed_review(job_id, documents, written) do
    Enum.each(documents, fn document ->
      :ok =
        Notifier.broadcast_review(
          job_id,
          document.id,
          :succeeded,
          nil,
          Map.get(written, document.id, 0)
        )
    end)

    :ok
  end

  defp fail_review(job_id, documents, reason) when is_binary(reason) do
    Enum.each(documents, fn document ->
      :ok = Notifier.broadcast_review(job_id, document.id, :failed, reason, 0)
    end)

    {:cancel, reason}
  end

  defp succeed(job_id, %Annotation{} = annotation) do
    :ok = Notifier.broadcast_annotation_reply(job_id, annotation, :succeeded, nil)
    :ok
  end

  # Said twice on purpose, the same way an estimation says it: the broadcast is
  # for the person watching and is gone once delivered; the `:cancel` leaves
  # the same words in the job's `errors`, which is where somebody debugging a
  # provider looks.
  defp fail(job_id, %Annotation{} = annotation, reason) when is_binary(reason) do
    :ok = Notifier.broadcast_annotation_reply(job_id, annotation, :failed, reason)
    {:cancel, reason}
  end

  defp failure_reason({:pi_exit, code, ""}), do: "the model call exited #{code}, saying nothing"
  defp failure_reason({:pi_exit, _code, complaint}), do: complaint
  defp failure_reason({:provider_refused, complaint}), do: complaint
  defp failure_reason(:stalled), do: "the model stopped responding"
  defp failure_reason(:empty_output), do: "the model answered with nothing"
  defp failure_reason(:pi_not_found), do: "the agent runtime is not installed on the server"
  defp failure_reason(:document_gone), do: "the document this annotation is on is gone"
  defp failure_reason(:invalid_output), do: "the model's answer was not a list of findings"
  defp failure_reason(other), do: inspect(other)

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
