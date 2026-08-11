defmodule RintoPMO.Agent.PromptBuilder do
  @moduledoc """
  Turns a chat message plus its references into a pi `prompt` command.

  ## Why references are structured

  pi's own file references are not a protocol -- `cli/file-processor.js` simply
  splices `<file name="...">content</file>` ahead of the message text, and
  nothing on pi's side parses it back. That leaves us free to choose how a
  reference travels from client to model, and the choice made here is to
  **never take a reference from the message body**. What is expanded is decided
  by `refs` alone; the body is read in exactly one bounded way, described under
  "Mentions" below, and never to discover a reference.

  The client sends what its mention UI already knows:

      %{"message" => "compare 《A》 and 《B》",
        "refs" => [%{"type" => "document", "id" => "0193..."},
                   %{"type" => "document", "id" => "0194..."}]}

  Scanning the text for `@name` or `#id` markers instead would mean inventing an
  escape syntax, guessing where a title ends, and changing two codebases every
  time that syntax moved.

  ## Mentions

  The message still has to point at the expansions, and the client writes those
  pointers as markdown links: `[document](reference#0)`, whose href indexes the
  `refs` array it sent. What the model reads is `[上线流程](ref#1)`, pointing at
  a handle the prelude stamped on the element itself.

  **That index does not survive the trip, so it is resolved here while the array
  is still at hand.** Two things invalidate it, and neither is avoidable on the
  client:

    * `dedupe_refs/1` collapses two mentions of one document into a single
      expansion, so four ref entries can become two elements and the later
      indices point at nothing
    * replay prepends its own refs, shifting every index the client chose

  Nor can the client dedupe its way out. Its mention UI has no way to reuse an
  entry already in the array, so mentioning one document twice necessarily sends
  it twice -- which is fine, and is why `RintoPMO.Conversations.MessageRef`
  positions are not unique per message.

  So the prelude hands out its own numbering. Every expansion is stamped with a
  `ref` attribute -- `<document ref="1" id="..." title="...">` -- and each href
  is rewritten to that handle: `[上线流程](ref#1)`. Both sides of the
  correlation now carry the same number, which is the thing the client's index
  never managed.

  The handle is deliberately not the id. An id is thirty-odd characters of
  hexadecimal repeated at every mention, which costs tokens and reads like
  nothing; a topic cites a handful of things, so one digit does the whole job.
  The id stays on the element, where it is written once and is what the model
  needs to name the thing back.

  Numbering from one, and reading `ref#` rather than `reference#`, keeps the
  rewritten form distinct from the client's -- a leftover index can never be
  mistaken for a handle, in a log or by a second pass over the same text.

  Two mentions of one document end up on the same handle, which is the truth: it
  is expanded once. The link text is replaced too, but only where the client
  left the bare type word as a placeholder, since `[document]` tells the model
  nothing the element does not already say.

  This is the one place that reads the body, and it reads only the href of a
  mention -- a delimited token, not prose, so nothing has to guess where a title
  ends. An index with no ref behind it is left exactly as it stands: nothing
  here knows what was meant, and inventing a target is worse than leaving a
  pointer that visibly goes nowhere.

  The body is otherwise untouched, and what is *stored* is always the client's
  original text: the rewrite happens on the way to the model, so a client
  reading its own history back still gets the hrefs it wrote.

  ## Reference forms

  | `type` | key | expands to |
  |---|---|---|
  | `document` | `id` | `<document>` holding the latest revision's blocks |
  | `annotation` | `id` + `document_id` | `<annotation>` and its replies |
  | `project` | `slug` | `<project>` and an index of its documents |
  | `attachment` | `id` | `<attachment>` marker plus an inline image |
  | `proposal` | `id` + `document_id` | `<proposal>` holding the proposed block text |

  Projects are keyed by `slug` because that is how they are addressed
  everywhere else here; annotations and proposals need `document_id` because
  they are only ever reachable through their document.

  Every one of them, and a reference that has gone missing, carries a `ref`
  attribute holding the handle its mentions point at. See "Mentions".

  ## Expansion terminates

  **Expanding a reference renders the thing itself and the parts belonging to
  it, and never follows a pointer to another entity.** Other entities appear as
  attributes -- an id, a title -- which are labels, not doorways. A document
  renders its blocks but not its annotations; an annotation renders its replies
  but not its document; a proposal renders its text but neither its document
  nor the topic that made it.

  That rule is what keeps every expansion a leaf. There is one shape that
  cannot obey it -- a conversation, whose messages carry references of their
  own -- and it is precisely the one that is not offered here.

  ## Replay

  A conversation is therefore not a reference a client may send. It is the
  `:replay` option, used in one situation: pi runs with `--no-session` and
  keeps no history, so a topic that has just been given a fresh process needs
  its recent turns handed back.

  Replay is assembled at send time and never stored, which is what keeps it out
  of `message_refs` -- it is the system restoring context, not the human citing
  something, and recording it as a citation would make a topic reference itself
  every time it woke up.

  What it renders is the tail of the transcript with each turn naming what it
  referenced, plus those references expanded once each **against the documents
  as they stand now**. Handing back the original expansion instead would feed a
  three-week-old snapshot to a model whose output is whole-block replacements,
  and a proposal written against stale text silently reverts everything that
  happened in between. Only one level is expanded: conversation references
  inside the replayed turns are dropped rather than followed.

  Attachments are the one type producing something other than text: the marker
  goes in the message so the model knows what the picture is called, and the
  bytes go in `images`. That pairing is pi's own -- an image passed as `@file`
  arrives the same way.

  Expanding an attachment also stamps its `last_used_at`. This is the only
  place in the system that can honestly say an image was used, so it is the
  only place that records it; see
  `RintoPMO.Attachments.touch_attachments/1` for why that matters.
  """

  alias RintoPMO.Annotations.Annotation
  alias RintoPMO.Annotations.AnnotationReply
  alias RintoPMO.Attachments.Attachment
  alias RintoPMO.Conversations.Conversation
  alias RintoPMO.Conversations.Message
  alias RintoPMO.Documents.BlockProposal
  alias RintoPMO.Documents.Document
  alias RintoPMO.Documents.DocumentRevision
  alias RintoPMO.Projects.Project
  alias RintoPMO.Utils

  @type built :: %{message: String.t(), images: [map()]}

  @type option ::
          {:replay, RintoPMO.Conversations.Conversation.t() | nil}
          | {:on_missing_refs, :fail | :skip}

  @doc """
  Expands `refs` and prepends them to `message`.

  Returns the message pi should receive and the images that go with it. With no
  references and no replay the message passes through untouched, so this is
  safe to call unconditionally.

  ## Options

    * `:replay` -- a conversation whose recent turns should be handed back to a
      pi process that has just been started. See "Replay" above.
    * `:on_missing_refs` -- `:fail` (the default) refuses the whole prompt and
      names every reference that could not be resolved; `:skip` renders those
      as unavailable and sends the rest. A caller offers `:skip` only after a
      human has seen the list and chosen to go ahead.

  A malformed reference is refused either way: `:skip` is for a reference whose
  target has since gone, which is ordinary, not for one the client built wrong.
  """
  @spec build(String.t(), [map()], [option()]) ::
          {:ok, built()} | {:error, atom(), map()}
  def build(message, refs \\ [], opts \\ [])

  def build(message, refs, opts) when is_binary(message) and is_list(refs) do
    replay = replay_turns(Keyword.get(opts, :replay))
    assemble(message, refs, replay, Keyword.get(opts, :on_missing_refs, :fail))
  end

  def build(_message, _refs, _opts), do: {:error, :invalid_ref, %{"refs" => ["must be a list"]}}

  defp assemble(message, refs, replay, on_missing) do
    # Replay's own references go first so that a document referenced three
    # weeks ago and again just now is expanded once, at its current state,
    # rather than twice.
    all_refs = dedupe_refs(replay_refs(replay) ++ refs)

    case resolve_all(all_refs, on_missing) do
      {:ok, resolved} ->
        # Stamped here rather than inside the attachment branch, so one query
        # covers a prompt however many images it carries, and so a prompt that
        # died on a later reference is not recorded as a use.
        resolved |> Enum.flat_map(& &1.attachment_ids) |> record_use()

        # Titles come from the entities `resolve/2` already fetched, so naming a
        # mention costs no query of its own.
        handles = handles_by_key(all_refs, resolved)
        texts = Enum.map(resolved, & &1.text) ++ transcript(replay, handles)

        # The client's own `refs`, not `all_refs`: the hrefs index the array it
        # sent, which is the one before replay prepended anything.
        body = rewrite_mentions(message, index_refs(refs), handles)

        {:ok,
         %{
           message: prepend_prelude(body, texts),
           images: Enum.flat_map(resolved, & &1.images)
         }}

      {:error, _code, _details} = error ->
        error
    end
  end

  # Every failure is collected rather than halting at the first, because the
  # caller's next move is to show a human the list and ask whether to go
  # ahead -- and being asked once per broken reference is not a choice, it is
  # an interrogation.
  defp resolve_all(refs, on_missing) do
    {resolved, missing, hard} =
      refs
      |> Enum.with_index(1)
      |> Enum.reduce({[], [], []}, fn {ref, handle}, {resolved, missing, hard} ->
        case resolve(ref, handle) do
          {:ok, expansion} ->
            {[expansion | resolved], missing, hard}

          {:error, :ref_not_found, details} ->
            {[unavailable(details, handle) | resolved], [details | missing], hard}

          # Anything else -- a malformed ref, unreadable attachment bytes -- is
          # not a target that has since gone, so it is neither collected nor
          # skippable. It is reported as itself.
          {:error, _code, _details} = error ->
            {resolved, missing, [error | hard]}
        end
      end)

    cond do
      hard != [] ->
        hard |> Enum.reverse() |> hd()

      missing != [] and on_missing == :fail ->
        {:error, :ref_not_found, %{"refs" => Enum.reverse(missing)}}

      true ->
        {:ok, Enum.reverse(resolved)}
    end
  end

  # A skipped reference still leaves a marker. Removing it outright would put
  # the model in front of "tighten this paragraph" with no paragraph and no
  # sign that one was ever meant to be there -- which is the silent loss the
  # whole strict-by-default rule exists to prevent.
  # It carries a handle like any other expansion: a mention pointing at it has
  # to land somewhere, and "the thing you cited is gone" is the answer.
  defp unavailable(details, handle) do
    attributes =
      [{"ref", handle}, {"status", "unavailable"}] ++
        for key <- ["type", "id", "document_id"],
            value = Map.get(details, key),
            do: {key, value}

    text_only(element("reference", attributes, "[No longer available.]"))
  end

  # Mentions

  # A markdown link whose href is `reference#` and a decimal index. The label
  # stops at `]` and cannot span lines, so an unclosed bracket somewhere in the
  # prose cannot swallow the rest of the message.
  @mention ~r/\[([^\]\n]*)\]\(reference#(\d+)\)/

  # The bare type words the client uses as placeholder link text. Only these are
  # replaced by a title -- anything else is a human's own words, or a label
  # already worth reading, and is left as written.
  @type_words ~w(document annotation project proposal attachment)

  defp rewrite_mentions(text, refs_by_index, _handles) when map_size(refs_by_index) == 0, do: text

  defp rewrite_mentions(text, refs_by_index, handles) do
    Regex.replace(@mention, text, fn whole, label, index ->
      with {:ok, ref} <- Map.fetch(refs_by_index, String.to_integer(index)),
           {:ok, %{handle: handle, label: title}} <- Map.fetch(handles, ref_key(ref)) do
        "[#{mention_label(label, title)}](ref##{handle})"
      else
        # No ref at that index, or one carrying no expansion. Either way this
        # side does not know what was meant.
        :error -> whole
      end
    end)
  end

  defp mention_label(label, title) when label in @type_words and is_binary(title), do: title
  defp mention_label(label, _title), do: label

  # One entry per expansion, keyed the way each kind of thing is addressed
  # everywhere else here, so two mentions of one document find the same handle.
  #
  # `resolved` is in `refs` order -- `resolve_all/2` restores it, and numbers the
  # handles off the same list -- so the two zip and the numbering agrees with
  # what the elements were stamped with.
  defp handles_by_key(refs, resolved) do
    refs
    |> Enum.zip(resolved)
    |> Enum.with_index(1)
    |> Map.new(fn {{ref, %{label: label}}, handle} ->
      {ref_key(ref), %{handle: handle, label: normalize_label(label)}}
    end)
  end

  # A title lands inside a markdown link on one line of prose, so a newline in
  # it would break the sentence around it.
  defp normalize_label(label) when is_binary(label) do
    case label |> String.replace(~r/\s+/, " ") |> String.trim() do
      "" -> nil
      normalized -> normalized
    end
  end

  defp normalize_label(_label), do: nil

  defp index_refs(refs) do
    refs |> Enum.with_index() |> Map.new(fn {ref, index} -> {index, ref} end)
  end

  # A stored ref carries the index it was sent under in `position`, which is what
  # makes the rewrite reproducible when a turn is replayed weeks later.
  defp turn_index_refs(%Message{refs: refs}) when is_list(refs) do
    Map.new(refs, fn ref -> {ref.position, ref.payload} end)
  end

  defp turn_index_refs(%Message{}), do: %{}

  defp prepend_prelude(message, []), do: message

  defp prepend_prelude(message, texts) do
    texts |> Enum.reject(&(&1 in [nil, ""])) |> Enum.join("\n") |> join_message(message)
  end

  defp join_message("", message), do: message
  defp join_message(prelude, message), do: prelude <> "\n\n" <> message

  # Replay

  defp replay_turns(nil), do: nil

  defp replay_turns(%Conversation{} = conversation) do
    messages = conversations().recent_messages(conversation, setting(:max_conversation_turns))
    %{conversation: conversation, messages: messages}
  end

  # The refs the replayed turns carried, re-expanded against the documents as
  # they stand *now*. Storing the expansion instead would hand a three-week-old
  # snapshot back to the model, and in a system whose whole output is
  # whole-block replacements, a proposal written against stale text silently
  # reverts whatever happened in between.
  #
  # Conversation refs are dropped rather than followed: one level only. A
  # transcript that expanded the transcripts it mentions has no bottom.
  defp replay_refs(nil), do: []

  defp replay_refs(%{messages: messages}) do
    messages
    |> Enum.flat_map(fn message -> Enum.map(message.refs, & &1.payload) end)
    |> Enum.reject(&(ref_type(&1) == "conversation"))
  end

  defp transcript(nil, _handles), do: []

  defp transcript(%{conversation: conversation, messages: messages}, handles) do
    [render_conversation(conversation, messages, handles)]
  end

  # Deduplicated by identity, keeping the first occurrence. A project is keyed
  # by slug and everything else by id, matching how each is addressed.
  defp dedupe_refs(refs), do: Enum.uniq_by(refs, &ref_key/1)

  defp ref_key(%{"type" => "project", "slug" => slug}), do: {"project", slug}
  defp ref_key(%{"type" => type, "id" => id}), do: {type, id}
  defp ref_key(ref), do: ref

  defp ref_type(%{"type" => type}) when is_binary(type), do: type
  defp ref_type(_ref), do: nil

  defp resolve(%{"type" => "document", "id" => id}, handle) when is_binary(id) do
    with {:ok, document} <- fetch(fn -> documents().get_document!(id) end, "document", id) do
      {:ok, text_only(render_document(document, handle), document_label(document))}
    end
  end

  defp resolve(%{"type" => "annotation", "id" => id, "document_id" => document_id}, handle)
       when is_binary(id) and is_binary(document_id) do
    with {:ok, document} <-
           fetch(fn -> documents().get_document!(document_id) end, "document", document_id),
         {:ok, annotation} <-
           fetch(fn -> annotations().get_annotation!(document, id) end, "annotation", id) do
      {:ok, text_only(render_annotation(annotation, handle))}
    end
  end

  defp resolve(%{"type" => "project", "slug" => slug}, handle) when is_binary(slug) do
    with {:ok, project} <- fetch(fn -> projects().get_project_by_slug!(slug) end, "project", slug) do
      {:ok, text_only(render_project(project, handle), project.name)}
    end
  end

  defp resolve(%{"type" => "proposal", "id" => id, "document_id" => document_id}, handle)
       when is_binary(id) and is_binary(document_id) do
    with {:ok, document} <-
           fetch(fn -> documents().get_document!(document_id) end, "document", document_id),
         {:ok, proposal} <-
           fetch(fn -> documents().get_proposal!(document, id) end, "proposal", id) do
      {:ok, text_only(render_proposal(proposal, handle))}
    end
  end

  defp resolve(%{"type" => "attachment", "id" => id}, handle) when is_binary(id) do
    with {:ok, attachment} <- fetch(fn -> attachments().get_attachment!(id) end, "attachment", id),
         {:ok, image} <- attachments().image_content(attachment) do
      {:ok,
       %{
         text: render_attachment(attachment, handle),
         images: [image],
         attachment_ids: [attachment.id],
         label: attachment.filename
       }}
    end
  end

  defp resolve(%{"type" => type}, _handle) when is_binary(type) do
    {:error, :invalid_ref, %{"type" => type, "reason" => "unknown type or missing key"}}
  end

  defp resolve(_ref, _handle), do: {:error, :invalid_ref, %{"type" => ["is missing"]}}

  # An annotation and a proposal get no label: neither has a title, and the type
  # word the client wrote already reads correctly in a sentence.
  defp text_only(text, label \\ nil),
    do: %{text: text, images: [], attachment_ids: [], label: label}

  # Most prompts reference no image at all; the context would no-op, but there
  # is no reason to reach it to find that out.
  defp record_use([]), do: :ok
  defp record_use(ids), do: attachments().touch_attachments(ids)

  # The contexts raise on a missing row, which suits a REST handler wanting a
  # 404 but not a resolver that has to say *which* reference went bad. A stale
  # id in a client's mention list is ordinary, so it is reported as a value.
  defp fetch(lookup, type, id) do
    {:ok, lookup.()}
  rescue
    Ecto.NoResultsError -> {:error, :ref_not_found, %{"type" => type, "id" => id}}
  end

  defp render_document(
         %Document{latest_revision: %DocumentRevision{} = revision} = document,
         handle
       ) do
    blocks = ordered_blocks(revision)
    {shown, truncated?} = take_within_budget(blocks)

    attributes =
      [
        {"ref", handle},
        {"id", document.id},
        {"title", revision.title},
        {"revision", revision.id},
        {"blocks", length(blocks)}
      ] ++ if truncated?, do: [{"truncated", "true"}], else: []

    body =
      shown
      |> Enum.map_join("\n\n", fn block -> "[block:#{block.block_id}]\n#{block.content}" end)
      |> append_truncation_note(truncated?)

    element("document", attributes, body)
  end

  defp render_document(%Document{} = document, handle) do
    element(
      "document",
      [{"ref", handle}, {"id", document.id}],
      "[Document has no revision snapshot.]"
    )
  end

  defp render_annotation(%Annotation{} = annotation, handle) do
    attributes =
      [{"ref", handle}, {"id", annotation.id}, {"document_id", annotation.document_id}] ++
        optional_attribute("block_id", annotation.block_id)

    body =
      join_present([
        anchor_line("block", annotation.block_text),
        anchor_line("selected", annotation.selected_text),
        annotation.content,
        replies(annotation)
      ])

    element("annotation", attributes, body)
  end

  defp render_project(%Project{} = project, handle) do
    attributes = [
      {"ref", handle},
      {"slug", project.slug},
      {"name", project.name},
      {"status", project.status}
    ]

    element(
      "project",
      attributes,
      join_present([project.description, project_documents(project)])
    )
  end

  # Each turn names what it referenced but does not repeat it: the expansions
  # are above, once each, and the model correlates them by id. That is the same
  # bargain the rest of this module strikes -- the message keeps the label, the
  # prelude holds the content.
  defp render_conversation(%Conversation{} = conversation, messages, handles) do
    attributes =
      [{"id", conversation.id}] ++
        optional_attribute("title", conversation.title) ++
        [{"turns", length(messages)}]

    body =
      Enum.map_join(messages, "\n", fn %Message{} = message ->
        turn_attributes =
          [{"role", message.role}, {"position", message.position}] ++
            optional_attribute("refs", turn_refs(message))

        # Each turn carries its own array, so the mapping is per message rather
        # than one table for the whole transcript.
        element(
          "turn",
          turn_attributes,
          rewrite_mentions(message.content, turn_index_refs(message), handles)
        )
      end)

    element("conversation", attributes, body)
  end

  defp turn_refs(%Message{refs: refs}) when is_list(refs) do
    refs
    |> Enum.reject(&(&1.ref_type == "conversation"))
    |> Enum.map_join(",", fn ref -> "#{ref.ref_type}:#{ref.ref_id || "?"}" end)
  end

  defp turn_refs(%Message{}), do: nil

  defp render_proposal(%BlockProposal{} = proposal, handle) do
    attributes =
      [
        {"ref", handle},
        {"id", proposal.id},
        {"block_id", proposal.block_id},
        {"status", proposal.status}
      ] ++ optional_attribute("conversation", proposal_topic(proposal))

    element("proposal", attributes, proposal.content)
  end

  # The source topic appears as its title -- a label, like `document_id` on an
  # annotation. Expanding the topic itself is exactly what a proposal reference
  # exists to avoid: the text is self-contained, so this expansion terminates.
  defp proposal_topic(%BlockProposal{conversation_id: nil}), do: nil

  defp proposal_topic(%BlockProposal{conversation_id: conversation_id}) do
    conversations().get_conversation!(conversation_id).title
  rescue
    Ecto.NoResultsError -> nil
  end

  defp render_attachment(%Attachment{} = attachment, handle) do
    attributes =
      [
        {"ref", handle},
        {"id", attachment.id},
        {"mime", attachment.mime_type},
        {"width", attachment.width},
        {"height", attachment.height}
      ] ++ optional_attribute("filename", attachment.filename)

    element("attachment", attributes, "")
  end

  defp project_documents(%Project{} = project) do
    documents = documents().list_documents({:project, project.id})
    limit = setting(:max_project_documents)

    listing =
      documents
      |> Enum.take(limit)
      |> Enum.map_join("\n", fn document -> "- #{document.id} #{document_title(document)}" end)

    cond do
      documents == [] -> "documents: none"
      length(documents) > limit -> "documents (#{limit} of #{length(documents)}):\n#{listing}"
      true -> "documents:\n#{listing}"
    end
  end

  defp document_title(%Document{latest_revision: %DocumentRevision{title: title}}), do: title
  defp document_title(%Document{}), do: "(untitled)"

  # Distinct from `document_title/1`: a row in a project's index has to say
  # something, but a mention with no title to offer is better left reading
  # "document" than "(untitled)".
  defp document_label(%Document{latest_revision: %DocumentRevision{title: title}}), do: title
  defp document_label(%Document{}), do: nil

  defp replies(%Annotation{replies: [_first | _rest] = replies}) do
    Enum.map_join(replies, "\n", fn %AnnotationReply{} = reply ->
      "<reply position=\"#{reply.position}\">#{reply.content}</reply>"
    end)
  end

  defp replies(%Annotation{}), do: nil

  defp anchor_line(_label, value) when value in [nil, ""], do: nil
  defp anchor_line(label, text), do: "#{label}: #{text}"

  # The budget counts characters rather than blocks: block sizes vary by orders
  # of magnitude, so a block count would either truncate short documents
  # needlessly or let a single huge block through unbounded. The first block is
  # always included, so an over-budget document still shows what it opens with.
  defp take_within_budget(blocks) do
    {shown, _left} =
      Enum.reduce_while(blocks, {[], setting(:max_document_chars)}, fn block, {taken, budget} ->
        remaining = budget - String.length(block.content)

        cond do
          remaining >= 0 -> {:cont, {[block | taken], remaining}}
          taken == [] -> {:halt, {[block], remaining}}
          true -> {:halt, {taken, remaining}}
        end
      end)

    shown = Enum.reverse(shown)
    {shown, length(shown) < length(blocks)}
  end

  defp ordered_blocks(%DocumentRevision{blocks: blocks}) when is_list(blocks) do
    Enum.sort_by(blocks, & &1.position)
  end

  defp ordered_blocks(%DocumentRevision{}), do: []

  defp append_truncation_note(body, false), do: body

  defp append_truncation_note(body, true) do
    body <> "\n\n[Remaining blocks omitted. Read the document for the full text.]"
  end

  defp element(tag, attributes, body) do
    open = "<#{tag}#{Enum.map_join(attributes, "", &attribute/1)}>"

    case String.trim(body) do
      "" -> open <> "</#{tag}>"
      trimmed -> open <> "\n" <> trimmed <> "\n</#{tag}>"
    end
  end

  defp optional_attribute(_name, value) when value in [nil, ""], do: []
  defp optional_attribute(name, value), do: [{name, value}]

  # Titles and filenames are user input landing inside a quoted attribute, so a
  # stray quote or newline would break the element open. The body is left alone:
  # documents are prose and code, and escaping it would change what the model
  # reads.
  defp attribute({name, value}) do
    escaped =
      value
      |> to_string()
      |> String.replace("\"", "&quot;")
      |> String.replace(~r/\s+/, " ")

    " #{name}=\"#{escaped}\""
  end

  defp join_present(parts) do
    parts
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join("\n")
  end

  defp documents, do: Utils.module(:documents)
  defp annotations, do: Utils.module(:annotations)
  defp conversations, do: Utils.module(:conversations)
  defp projects, do: Utils.module(:projects)
  defp attachments, do: Utils.module(:attachments)

  defp setting(key) do
    :rinto_pmo
    |> Application.fetch_env!(__MODULE__)
    |> Keyword.fetch!(key)
  end
end
