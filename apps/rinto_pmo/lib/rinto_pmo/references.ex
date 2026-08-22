defmodule RintoPMO.References do
  @moduledoc """
  The `rinto://` addressing scheme: what a body of text may point at.

  A reference is written in the text itself, as an ordinary Markdown link whose
  destination happens to be ours:

      见 [上线流程](rinto://document/0193...) 的第二节

  ## Why the reference lives in the text

  Chat messages carry references beside the body, in `message_refs`, and
  `RintoPMO.Agent.PromptBuilder` will not read one out of a message body. That
  works because a message is written once by a client whose mention UI
  maintains the array.

  **Document bodies have no such client.** A block is rewritten wholesale by a
  model inside a proposal, and nothing on that path maintains a sidecar. So a
  reference written into a document has to be self-contained -- carried by the
  text, surviving whatever rewrites the text.

  `PromptBuilder`'s objection to reading the body was that it would mean
  inventing an escape syntax and guessing where a title ends. It also says, in
  the same breath, that reading a mention's href is safe because an href is a
  bounded token rather than prose. A Markdown link destination is that same
  bounded token, so the objection does not reach this.

  ## The shape

      rinto://{type}/{key}

  One shape, no exceptions:

      rinto://project/{slug}        rinto://task/{id}
      rinto://document/{id}         rinto://conversation/{id}
      rinto://block/{id}            rinto://attachment/{id}
      rinto://annotation/{id}       rinto://proposal/{id}

  **Nothing is nested under its parent.** A block's document is not in the URI
  even though a block always has one: `RintoPMO.Links` resolves the parent when
  it indexes the reference and stores it there, the same way
  `RintoPMO.Conversations.MessageRef` stores the id a project slug resolved to
  at write time. The index carries the parent pointer so the address does not
  have to, which leaves every type addressed the same way.

  **`:` never separates the type from the key.** `rinto://block:0193...` parses
  as a host and a port under RFC 3986 -- the identifier is silently truncated at
  the first non-digit and no error is raised. The `//` is kept because it is
  what makes the scheme look like a URL to everything downstream: MDEx
  autolinks a bare one, and a client that already special-cases URL schemes
  needs no new notion to intercept it.

  ## Unknown types parse

  `parse/1` succeeds for a well-formed URI whose type this build does not know,
  and `linkable?/1` then answers false. This follows `MessageRef`, where an
  unknown ref type is stored and ignored rather than failing the write that
  carried it: a body mentioning a kind of thing that does not exist yet should
  still save, and should still render as an ordinary link.

  A *malformed* URI is a different answer -- `:error` -- and so is a known type
  whose key is not shaped like the identifier that type uses. Those are
  mistakes, not futures.
  """

  alias RintoPMO.Documents.Markdown
  alias RintoPMO.References.Reference

  @scheme "rinto://"

  # Free-form rather than an enum for the same reason `MessageRef.ref_type` is:
  # the set grows, and growth should not invalidate text already written.
  @type_format ~r/^[a-z][a-z_]*$/

  # A slug is what `RintoPMO.Projects` already accepts. Kept loose on purpose --
  # this checks the shape of an address, not whether the thing exists, which is
  # a separate pass with a database behind it.
  @slug_format ~r/^[a-z0-9][a-z0-9\-_]*$/i

  @typedoc """
  A reference found in a body, with the link text that introduced it.

  `position` counts references, not links: a body whose only `rinto://` link is
  its third link reports it at position 0. Nothing points at these numbers --
  they exist so that two references to one target stay distinguishable and
  ordered.
  """
  @type extracted :: %{
          reference: Reference.t(),
          label: String.t(),
          position: non_neg_integer()
        }

  @typedoc """
  What a type may do.

    * `key` -- whether the URI's second segment is an id or a slug
    * `linkable` -- may be the target of a reference
    * `expandable` -- may be inlined into a prompt by `PromptBuilder`
    * `searchable` -- has a projection in the search index
  """
  @type capabilities :: %{
          key: :id | :slug,
          linkable: boolean(),
          expandable: boolean(),
          searchable: boolean()
        }

  @types %{
    "project" => %{key: :slug, linkable: true, expandable: true, searchable: true},
    "document" => %{key: :id, linkable: true, expandable: true, searchable: true},
    "block" => %{key: :id, linkable: true, expandable: true, searchable: true},
    "annotation" => %{key: :id, linkable: true, expandable: true, searchable: true},
    "task" => %{key: :id, linkable: true, expandable: true, searchable: true},
    "attachment" => %{key: :id, linkable: true, expandable: true, searchable: true},

    # Linkable but not expandable, which is the distinction that lets a topic be
    # cited at all. Expanding a conversation is what has no bottom -- every
    # message in it carries references of its own -- and that is a property of
    # expansion, not of naming the thing. See docs/api-frontend-guide.md.
    "conversation" => %{key: :id, linkable: true, expandable: false, searchable: true},

    # The one type that is linkable without a projection of its own. A proposal
    # is only ever reached through the document it is proposed against, so
    # surfacing it as an independent search hit would offer a target nobody
    # navigates to directly. This is the exception the invariant below allows.
    "proposal" => %{key: :id, linkable: true, expandable: true, searchable: false}
  }

  @doc """
  The type registry: what each addressable kind of thing may do.
  """
  @spec types() :: %{String.t() => capabilities()}
  def types, do: @types

  @doc """
  Parses a `rinto://` URI.

  Returns `:error` for anything that is not one, for a malformed one, and for a
  known type whose key is not shaped like that type's identifier. Succeeds for
  an unknown type -- see the module documentation.

  ## Examples

      iex> RintoPMO.References.parse("rinto://project/infra")
      {:ok, %RintoPMO.References.Reference{type: "project", key: "infra"}}

      iex> RintoPMO.References.parse("rinto://intel/anything")
      {:ok, %RintoPMO.References.Reference{type: "intel", key: "anything"}}

      iex> RintoPMO.References.parse("https://example.com")
      :error
  """
  @spec parse(String.t()) :: {:ok, Reference.t()} | :error
  def parse(@scheme <> rest) when is_binary(rest) do
    with [type, key] <- String.split(rest, "/"),
         true <- Regex.match?(@type_format, type),
         true <- valid_key?(type, key) do
      {:ok, %Reference{type: type, key: key}}
    else
      _no -> :error
    end
  end

  def parse(uri) when is_binary(uri), do: :error

  @doc """
  Renders a reference back to its URI.

  ## Examples

      iex> RintoPMO.References.to_uri(%RintoPMO.References.Reference{type: "task", key: "abc"})
      "rinto://task/abc"
  """
  @spec to_uri(Reference.t()) :: String.t()
  def to_uri(%Reference{type: type, key: key}), do: @scheme <> type <> "/" <> key

  @doc """
  Finds every `rinto://` reference in a Markdown body, in document order.

  Links that are not references are skipped, and so is anything inside a code
  block -- see `RintoPMO.Documents.Markdown.links/1` for why that comes free.

  ## Examples

      iex> id = "01936f2a-1c4e-7c3a-9f1b-2d4e6a8b0c1d"
      iex> RintoPMO.References.extract("[a](rinto://task/\#{id}) and [b](https://x.test)")
      {:ok, [%{reference: %RintoPMO.References.Reference{type: "task", key: "01936f2a-1c4e-7c3a-9f1b-2d4e6a8b0c1d"},
               label: "a", position: 0}]}
  """
  @spec extract(String.t()) :: {:ok, [extracted()]} | {:error, term()}
  def extract(markdown) when is_binary(markdown) do
    with {:ok, links} <- Markdown.links(markdown) do
      extracted =
        links
        |> Enum.flat_map(fn link ->
          case parse(link.url) do
            {:ok, reference} -> [%{reference: reference, label: link.label}]
            :error -> []
          end
        end)
        |> Enum.with_index()
        |> Enum.map(fn {found, position} -> Map.put(found, :position, position) end)

      {:ok, extracted}
    end
  end

  @doc """
  Whether this reference may be indexed and resolved.

  False for a type this build does not know, which is how an unknown type ends
  up stored in the text, rendered as a plain link, and absent from the index.
  """
  @spec linkable?(Reference.t()) :: boolean()
  def linkable?(%Reference{type: type}), do: capability(type, :linkable)

  @doc """
  Whether `RintoPMO.Agent.PromptBuilder` may inline this reference's target.
  """
  @spec expandable?(Reference.t()) :: boolean()
  def expandable?(%Reference{type: type}), do: capability(type, :expandable)

  @doc """
  Whether this type is projected into the search index.
  """
  @spec searchable?(Reference.t()) :: boolean()
  def searchable?(%Reference{type: type}), do: capability(type, :searchable)

  @doc """
  The reference's key when its type is addressed by id, otherwise `nil`.
  """
  @spec id(Reference.t()) :: String.t() | nil
  def id(%Reference{type: type, key: key}), do: if(key_kind(type) == :id, do: key)

  @doc """
  The reference's key when its type is addressed by slug, otherwise `nil`.
  """
  @spec slug(Reference.t()) :: String.t() | nil
  def slug(%Reference{type: type, key: key}), do: if(key_kind(type) == :slug, do: key)

  defp capability(type, name) do
    case Map.fetch(@types, type) do
      {:ok, capabilities} -> Map.fetch!(capabilities, name)
      :error -> false
    end
  end

  defp key_kind(type) do
    case Map.fetch(@types, type) do
      {:ok, %{key: kind}} -> kind
      :error -> nil
    end
  end

  # An unknown type has no declared key, so there is nothing to check it
  # against and the address is taken as written.
  defp valid_key?(type, key) do
    case key_kind(type) do
      :id -> match?({:ok, _uuid}, Ecto.UUID.cast(key))
      :slug -> Regex.match?(@slug_format, key)
      nil -> key != ""
    end
  end
end
