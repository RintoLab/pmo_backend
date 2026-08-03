defmodule RintoPMO.Agent.PromptBuilder do
  @moduledoc """
  Turns a chat message plus its references into a pi `prompt` command.

  ## Why references are structured

  pi's own file references are not a protocol -- `cli/file-processor.js` simply
  splices `<file name="...">content</file>` ahead of the message text, and
  nothing on pi's side parses it back. That leaves us free to choose how a
  reference travels from client to model, and the choice made here is to
  **never parse the message body**.

  The client sends what its mention UI already knows:

      %{"message" => "compare 《A》 and 《B》",
        "refs" => [%{"type" => "document", "id" => "0193..."},
                   %{"type" => "document", "id" => "0194..."}]}

  Scanning the text for `@name` or `#id` markers instead would mean inventing an
  escape syntax, guessing where a title ends, and changing two codebases every
  time that syntax moved. The message keeps whatever human-readable label the
  client put in it; the model correlates it with the expanded prelude through
  the titles and ids rendered there.

  ## Reference forms

  | `type` | key | expands to |
  |---|---|---|
  | `document` | `id` | `<document>` holding the latest revision's blocks |
  | `annotation` | `id` + `document_id` | `<annotation>` and its replies |
  | `project` | `slug` | `<project>` and an index of its documents |
  | `attachment` | `id` | `<attachment>` marker plus an inline image |

  Projects are keyed by `slug` because that is how they are addressed
  everywhere else here; an annotation needs `document_id` because it is only
  ever reachable through its document.

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
  alias RintoPMO.Documents.Document
  alias RintoPMO.Documents.DocumentRevision
  alias RintoPMO.Projects.Project
  alias RintoPMO.Utils

  @type built :: %{message: String.t(), images: [map()]}

  @doc """
  Expands `refs` and prepends them to `message`.

  Returns the message pi should receive and the images that go with it. With no
  references the message passes through untouched, so this is safe to call
  unconditionally.
  """
  @spec build(String.t(), [map()]) :: {:ok, built()} | {:error, atom(), map()}
  def build(message, refs \\ [])

  def build(message, []) when is_binary(message) do
    {:ok, %{message: message, images: []}}
  end

  def build(message, refs) when is_binary(message) and is_list(refs) do
    case resolve_all(refs) do
      {:ok, resolved} ->
        # Stamped here rather than inside the attachment branch, so one query
        # covers a prompt however many images it carries, and so a prompt that
        # died on a later reference is not recorded as a use.
        resolved |> Enum.flat_map(& &1.attachment_ids) |> record_use()

        {:ok,
         %{
           message: prepend_prelude(message, Enum.map(resolved, & &1.text)),
           images: Enum.flat_map(resolved, & &1.images)
         }}

      {:error, _code, _details} = error ->
        error
    end
  end

  def build(_message, _refs), do: {:error, :invalid_ref, %{"refs" => ["must be a list"]}}

  defp resolve_all(refs) do
    Enum.reduce_while(refs, {:ok, []}, fn ref, {:ok, acc} ->
      case resolve(ref) do
        {:ok, resolved} -> {:cont, {:ok, [resolved | acc]}}
        {:error, _code, _details} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, resolved} -> {:ok, Enum.reverse(resolved)}
      error -> error
    end
  end

  defp prepend_prelude(message, []), do: message
  defp prepend_prelude(message, texts), do: Enum.join(texts, "\n") <> "\n\n" <> message

  defp resolve(%{"type" => "document", "id" => id}) when is_binary(id) do
    with {:ok, document} <- fetch(fn -> documents().get_document!(id) end, "document", id) do
      {:ok, text_only(render_document(document))}
    end
  end

  defp resolve(%{"type" => "annotation", "id" => id, "document_id" => document_id})
       when is_binary(id) and is_binary(document_id) do
    with {:ok, document} <-
           fetch(fn -> documents().get_document!(document_id) end, "document", document_id),
         {:ok, annotation} <-
           fetch(fn -> annotations().get_annotation!(document, id) end, "annotation", id) do
      {:ok, text_only(render_annotation(annotation))}
    end
  end

  defp resolve(%{"type" => "project", "slug" => slug}) when is_binary(slug) do
    with {:ok, project} <- fetch(fn -> projects().get_project_by_slug!(slug) end, "project", slug) do
      {:ok, text_only(render_project(project))}
    end
  end

  defp resolve(%{"type" => "attachment", "id" => id}) when is_binary(id) do
    with {:ok, attachment} <- fetch(fn -> attachments().get_attachment!(id) end, "attachment", id),
         {:ok, image} <- attachments().image_content(attachment) do
      {:ok,
       %{
         text: render_attachment(attachment),
         images: [image],
         attachment_ids: [attachment.id]
       }}
    end
  end

  defp resolve(%{"type" => type}) when is_binary(type) do
    {:error, :invalid_ref, %{"type" => type, "reason" => "unknown type or missing key"}}
  end

  defp resolve(_ref), do: {:error, :invalid_ref, %{"type" => ["is missing"]}}

  defp text_only(text), do: %{text: text, images: [], attachment_ids: []}

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

  defp render_document(%Document{latest_revision: %DocumentRevision{} = revision} = document) do
    blocks = ordered_blocks(revision)
    {shown, truncated?} = take_within_budget(blocks)

    attributes =
      [
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

  defp render_document(%Document{} = document) do
    element("document", [{"id", document.id}], "[Document has no revision snapshot.]")
  end

  defp render_annotation(%Annotation{} = annotation) do
    attributes =
      [{"id", annotation.id}, {"document_id", annotation.document_id}] ++
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

  defp render_project(%Project{} = project) do
    attributes = [
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

  defp render_attachment(%Attachment{} = attachment) do
    attributes =
      [
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
  defp projects, do: Utils.module(:projects)
  defp attachments, do: Utils.module(:attachments)

  defp setting(key) do
    :rinto_pmo
    |> Application.fetch_env!(__MODULE__)
    |> Keyword.fetch!(key)
  end
end
