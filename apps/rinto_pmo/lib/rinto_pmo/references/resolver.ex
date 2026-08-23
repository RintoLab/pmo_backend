defmodule RintoPMO.References.Resolver do
  @moduledoc """
  Turns `rinto://` URIs into enough of their targets to render a link.

  `RintoPMO.References` parses an address; this reads what is at it. Both steps
  are needed and only the second one has a database behind it, which is why they
  are separate modules: parsing is used on the write path all over the system
  and must never be mocked, while this is a read a controller test replaces.

  ## Why the client cannot do this itself

  A client holds the body, so it can find its own outbound references without
  asking. What it cannot do is answer **what is there** -- the title to preview,
  whether the target still exists, whether it has been archived. Those are the
  three things a reference needs before it can be rendered as anything other
  than raw text, and all three are here.

  ## Why in bulk

  A body carries as many references as its author wrote. Resolving them one
  request at a time makes rendering a document cost a round trip per link, so
  the entry point takes a list and answers a list.

  **The answer is positional.** Results come back in the order asked, and a URI
  repeated in the request is repeated in the response, because the caller maps
  results onto occurrences in the text and a collapsed list would misalign them.

  ## Four states, and why `broken` is not `invalid`

    * `:ok` -- resolved, and the target is there
    * `:broken` -- a known type, correctly addressed, that is not there any more
    * `:unknown_type` -- well-formed, but naming a type this build has no notion
      of (see `RintoPMO.References` on why that is not an error)
    * `:invalid` -- not a well-formed `rinto://` URI at all

  A caller renders `:broken` and `:invalid` about the same -- degraded, not
  followable -- but it should only *say* something was deleted for the first.
  The second means the address was never good, which is a different thing to
  show a reader and a different thing to fix.

  One bad URI does not fail the batch. A single mistyped reference in a long
  document would otherwise take the other thirty links down with it.

  ## No URLs in the answer

  A result carries a type and identifiers, never a path the client should
  navigate to. Choosing `rinto://` over `/documents/{id}` in the first place was
  a refusal to bind stored content to the web application's routes, and handing
  back routes here would reintroduce exactly that: a route rename would then
  have to rewrite bodies in the database.

  A block result carries `document_id` because a block's document is a fact
  about the resources, not a route -- following a block reference means opening
  that document at that block, and the client should not need a second call to
  learn which document that is.
  """

  use RintoPMO, :context

  alias RintoPMO.Annotations.Annotation
  alias RintoPMO.Attachments.Attachment
  alias RintoPMO.Conversations.Conversation
  alias RintoPMO.Documents.BlockProposal
  alias RintoPMO.Documents.Document
  alias RintoPMO.Documents.DocumentBlock
  alias RintoPMO.Documents.Revisions
  alias RintoPMO.Projects.Project
  alias RintoPMO.References
  alias RintoPMO.References.Reference
  alias RintoPMO.Tasks.Task
  alias RintoPMO.Text

  @type state :: :ok | :broken | :unknown_type | :invalid

  @type resolved :: %{
          uri: String.t(),
          type: String.t() | nil,
          state: state(),
          title: String.t() | nil,
          subtitle: String.t() | nil,
          excerpt: String.t() | nil,
          document_id: UUIDv7.t() | nil,
          document_title: String.t() | nil,
          archived: boolean()
        }

  defmodule Behaviour do
    @moduledoc false

    @callback resolve([String.t()]) ::
                {:ok, [RintoPMO.References.Resolver.resolved()]}
                | {:error, :too_many_references, map()}
  end

  @behaviour Behaviour

  @doc """
  Resolves `uris`, answering one result per input, in order.

  Refuses a batch over the configured `:max_references` rather than truncating
  it: a caller that silently got half its links back would render the rest as
  broken, which looks like data loss rather than a limit.
  """
  @impl true
  def resolve(uris) when is_list(uris) do
    if length(uris) > max_references() do
      {:error, :too_many_references, %{max: max_references(), given: length(uris)}}
    else
      parsed = Enum.map(uris, &{&1, References.parse(&1)})
      {:ok, Enum.map(parsed, &render(&1, targets(parsed)))}
    end
  end

  @doc """
  Checks that every `rinto://` reference in `text` points at something.

  Answers the offending URIs rather than a boolean, because the caller's job is
  to tell a model which addresses to fix -- "one of your links is wrong" sends
  it back to re-read a whole document.

  ## What counts as wrong

  A **known type with no such row**. That is a mistyped identifier, and there is
  no legitimate reading of it: an address is a UUID handed out by search or by
  the call that created the thing, and the one exception -- a project's slug --
  cannot change once the project exists. So an address that was good when it was
  written stays good, and there is no equivalent of a wiki's link to a page
  nobody has written yet.

  An **unknown type is not wrong** -- see `RintoPMO.References`. Text mentioning
  a kind of thing this build has not learned yet still saves, still renders, and
  simply is not indexed.

  Neither is a **malformed URI**: it is not a reference at all, just a link
  whose destination happens to start with those characters, and refusing a body
  over one would make this a validator of link syntax rather than of references.

  ## Not through the injector

  Called directly rather than through `Utils.module(:reference_resolver)`, for
  the reason `RintoPMO.Links` is: this is part of writing correctly, and a mock
  in its place would let a write test pass over references that were never
  checked.
  """
  @spec validate(term()) :: :ok | {:error, [String.t()]}
  def validate(""), do: :ok

  # Anything that is not text has no references in it, and is refused further
  # along by whatever was going to store it. Deciding here that a number is an
  # invalid body would move a validation into the wrong module and answer with
  # the wrong error.
  def validate(text) when not is_binary(text), do: :ok

  def validate(text) do
    case References.extract(text) do
      {:ok, found} -> refuse_absent(found)
      # A body the Markdown parser cannot read has no references to check, and
      # is refused further along by whatever was going to store it.
      {:error, _reason} -> :ok
    end
  end

  defp refuse_absent(found) do
    found
    |> Enum.map(& &1.reference)
    |> Enum.filter(&References.linkable?/1)
    |> Enum.uniq()
    |> missing()
    |> case do
      [] -> :ok
      absent -> {:error, Enum.map(absent, &References.to_uri/1)}
    end
  end

  defp missing([]), do: []

  defp missing(references) do
    present =
      references
      |> Enum.group_by(& &1.type, & &1.key)
      |> Map.new(fn {type, keys} -> {type, load(type, Enum.uniq(keys))} end)

    Enum.reject(references, fn reference ->
      present |> Map.fetch!(reference.type) |> Map.has_key?(reference.key)
    end)
  end

  # One query per type actually asked for, rather than one per reference.
  defp targets(parsed) do
    parsed
    |> Enum.flat_map(fn
      {_uri, {:ok, reference}} -> if References.linkable?(reference), do: [reference], else: []
      {_uri, :error} -> []
    end)
    |> Enum.group_by(& &1.type, & &1.key)
    |> Map.new(fn {type, keys} -> {type, load(type, Enum.uniq(keys))} end)
  end

  defp render({uri, :error}, _targets), do: blank(uri, nil, :invalid)

  defp render({uri, {:ok, %Reference{type: type, key: key} = reference}}, targets) do
    cond do
      not References.linkable?(reference) ->
        blank(uri, type, :unknown_type)

      found = targets |> Map.fetch!(type) |> Map.get(key) ->
        Map.merge(found, %{uri: uri, type: type, state: :ok})

      true ->
        blank(uri, type, :broken)
    end
  end

  defp blank(uri, type, state) do
    %{
      uri: uri,
      type: type,
      state: state,
      title: nil,
      subtitle: nil,
      excerpt: nil,
      document_id: nil,
      document_title: nil,
      archived: false
    }
  end

  defp projection(fields) do
    Map.merge(
      %{
        title: nil,
        subtitle: nil,
        excerpt: nil,
        document_id: nil,
        document_title: nil,
        archived: false
      },
      fields
    )
  end

  # Loading

  defp load("project", slugs) do
    Project
    |> where([project], project.slug in ^slugs)
    |> Repo.all()
    |> Map.new(fn project ->
      {project.slug,
       projection(%{
         title: project.name,
         excerpt: excerpt(project.description),
         archived: project.status == :archived
       })}
    end)
  end

  defp load("document", ids) do
    Document
    |> join(:inner, [document], revision in subquery(Revisions.latest()),
      on: revision.document_id == document.id
    )
    |> where([document], document.id in ^ids)
    |> select([document, revision], {document, revision.title})
    |> Repo.all()
    |> Map.new(fn {document, title} ->
      {document.id,
       projection(%{
         title: title,
         subtitle: to_string(document.status),
         archived: not is_nil(document.archived_at)
       })}
    end)
  end

  # A block is addressed on its own, but only the copy in its document's latest
  # revision counts as present. Matching any revision would report a block
  # deleted three revisions ago as alive, because block rows are per-revision
  # snapshots and the old ones never go away.
  defp load("block", ids) do
    DocumentBlock
    |> join(:inner, [block], revision in subquery(Revisions.latest()),
      on: revision.id == block.revision_id
    )
    |> join(:inner, [_block, revision], document in Document,
      on: document.id == revision.document_id
    )
    |> where([block], block.block_id in ^ids)
    |> select([block, revision, document], {block, revision, document.archived_at})
    |> Repo.all()
    |> Map.new(fn {block, revision, archived_at} ->
      {block.block_id,
       projection(%{
         title: Text.heading(block.content),
         subtitle: revision.title,
         excerpt: excerpt(block.content),
         document_id: revision.document_id,
         document_title: revision.title,
         archived: not is_nil(archived_at)
       })}
    end)
  end

  defp load("annotation", ids) do
    Annotation
    |> join(:inner, [annotation], revision in subquery(Revisions.latest()),
      on: revision.document_id == annotation.document_id
    )
    |> where([annotation], annotation.id in ^ids)
    |> select([annotation, revision], {annotation, revision.title})
    |> Repo.all()
    |> Map.new(fn {annotation, document_title} ->
      {annotation.id,
       projection(%{
         title: document_title,
         subtitle: to_string(annotation.status),
         excerpt: excerpt(annotation.content),
         document_id: annotation.document_id,
         document_title: document_title
       })}
    end)
  end

  defp load("proposal", ids) do
    BlockProposal
    |> join(:inner, [proposal], revision in subquery(Revisions.latest()),
      on: revision.document_id == proposal.document_id
    )
    |> where([proposal], proposal.id in ^ids)
    |> select([proposal, revision], {proposal, revision.title})
    |> Repo.all()
    |> Map.new(fn {proposal, document_title} ->
      {proposal.id,
       projection(%{
         title: document_title,
         subtitle: to_string(proposal.status),
         excerpt: excerpt(proposal.content),
         document_id: proposal.document_id,
         document_title: document_title
       })}
    end)
  end

  defp load("task", ids) do
    Task
    |> where([task], task.id in ^ids)
    |> Repo.all()
    |> Map.new(fn task ->
      {task.id,
       projection(%{
         title: task.title,
         subtitle: to_string(task.status),
         excerpt: excerpt(task.description)
       })}
    end)
  end

  # Only the title, never the messages. A topic is a transcript, and putting
  # any of it in a hover card would surface half a conversation as though it
  # were a conclusion -- the same reason a conversation is linkable but not
  # expandable in `RintoPMO.References`.
  defp load("conversation", ids) do
    Conversation
    |> where([conversation], conversation.id in ^ids)
    |> Repo.all()
    |> Map.new(&{&1.id, projection(%{title: &1.title})})
  end

  defp load("attachment", ids) do
    Attachment
    |> where([attachment], attachment.id in ^ids)
    |> Repo.all()
    |> Map.new(fn attachment ->
      {attachment.id, projection(%{title: attachment.filename, subtitle: attachment.mime_type})}
    end)
  end

  # Projecting

  defp excerpt(text), do: Text.excerpt(text, config(:max_excerpt_chars))

  defp max_references, do: config(:max_references)

  defp config(key) do
    :rinto_pmo
    |> Application.fetch_env!(__MODULE__)
    |> Keyword.fetch!(key)
  end
end
