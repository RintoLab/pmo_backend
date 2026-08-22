defmodule RintoPMO.Documents.Markdown do
  @moduledoc """
  Cuts an authored Markdown body into document blocks at its headings.

  This is the one place a document's structure is inferred rather than stated.
  Everything downstream -- `RintoPMO.Documents.BlockOps`, proposals, annotations
  -- works on blocks that already exist, so the grain chosen here is the grain
  the whole collaboration model gets.

  ## Why H1, H2 and H3

  Contention is detected per block: two live proposals on one block *is* the
  conflict (`RintoPMO.Documents`). That test only stays useful while a block is
  roughly a section -- coarse blocks make two unrelated edits collide routinely,
  and most of those collisions are false, two topics having touched different
  sentences of one large block.

  Real documents hang several `###` subsections under one `##`, so cutting at
  `##` alone yields blocks far larger than that assumption tolerates. `####` and
  deeper stay with their parent: past three levels a fragment stops being
  something a person can review on its own.

  `#` cuts like the rest. A document's title is a separate field and is never
  read out of the body, so an H1 here is ordinary structure and a body may carry
  several. Exempting only the shallowest level would glue the second `#` onto
  whatever preceded it -- the inconsistency would be the exemption, not the cut.

  ## Why the AST, not the lines

  Headings are found by parsing, so `##` inside a fenced code block, an indented
  code block, or an HTML block is content and does not cut. The block bodies are
  then rendered back from the AST, which means they are normalised Markdown
  rather than the author's exact bytes: bullets become `-`, tables get padded
  delimiter rows, ambiguous characters get escaped. That is accepted -- the
  content is Markdown, not text that happens to look like it, and normalising
  once at the door beats storing near-identical spellings of the same block.

  One artifact is worth knowing about: a list immediately followed by a code
  block or another list comes back with an `<!-- end list -->` between them.
  The renderer needs it -- without the separator the two would merge when the
  block is read back -- so it is left alone. It is invisible wherever the block
  is rendered, and visible only to someone editing the block's source.
  """

  alias MDEx.Document
  alias MDEx.Heading
  alias MDEx.Link
  alias MDEx.Text

  # Both directions share these: an extension that is off while parsing turns a
  # table into an escaped paragraph, and one that is off while rendering turns
  # the parsed table back into pipes nothing will read as a table again.
  @options [
    extension: [
      strikethrough: true,
      table: true,
      autolink: true,
      tasklist: true,
      footnotes: true
    ],
    render: [
      # Renders each paragraph on one line. Any other width would rewrap the
      # author's prose, which shows up as noise in every later diff.
      width: 0,
      # Without this a code block that carries no language degrades into an
      # indented one, which reads as a different thing to anyone who opens the
      # block to edit it.
      prefer_fenced: true
    ]
  ]

  @cut_depth 3

  @doc """
  Splits `markdown` into block contents, in document order.

  Content before the first heading becomes its own leading block. Sections that
  are blank after trimming are dropped, so blank lines between sections and a
  trailing newline cost nothing. Blank input yields `{:ok, []}`.

  ## Examples

      iex> RintoPMO.Documents.Markdown.split("## One\\n\\nfirst\\n\\n### Two\\n\\nsecond")
      {:ok, ["## One\\n\\nfirst", "### Two\\n\\nsecond"]}

      iex> RintoPMO.Documents.Markdown.split("preamble\\n\\n## One\\n\\nfirst")
      {:ok, ["preamble", "## One\\n\\nfirst"]}
  """
  @spec split(String.t()) :: {:ok, [String.t()]} | {:error, term()}
  def split(markdown) when is_binary(markdown) do
    with {:ok, document} <- MDEx.parse_document(markdown, @options) do
      document.nodes
      |> sections()
      |> render_all(document)
    end
  end

  @typedoc """
  One markdown link, as `links/1` reports it.

  `position` is the link's index among the links of the body it was read from,
  counting from zero.
  """
  @type link :: %{url: String.t(), label: String.t(), position: non_neg_integer()}

  @doc """
  Lists the links in `markdown`, in document order.

  Every link, whatever its destination -- this module knows Markdown, not what
  a URL means. `RintoPMO.References` is what decides which of these point at
  something in this system.

  ## Why this and not a parsed tree

  Reference extraction needs the same extensions `split/1` parses with, and
  handing out either the option list or the tree would leave getting that right
  to the caller. Neither failure is loud: a caller that parses without `table`
  sees a table as an escaped paragraph, and a caller that walks the tree itself
  has to know that a heading inside a list item is not top level.

  Returning the links themselves keeps the whole MDEx dependency inside this
  module, which is where it already was.

  ## Why the AST, not a regular expression

  Same reason `split/1` cuts on parsed headings: a link written inside a fenced
  or indented code block is content, and MDEx does not produce a link node
  there, so it is skipped without anything having to recognise a fence. Links
  inside block quotes and list items *are* reported -- they are ordinary prose
  that happens to be nested.

  Note that `autolink` is on, so a bare URL in the text is a link too, and its
  label is the URL itself.

  ## Examples

      iex> RintoPMO.Documents.Markdown.links("see [one](https://example.com)")
      {:ok, [%{url: "https://example.com", label: "one", position: 0}]}

      iex> RintoPMO.Documents.Markdown.links("```\\n[one](https://example.com)\\n```")
      {:ok, []}
  """
  @spec links(String.t()) :: {:ok, [link()]} | {:error, term()}
  def links(markdown) when is_binary(markdown) do
    with {:ok, document} <- MDEx.parse_document(markdown, @options) do
      links =
        document
        |> Enum.filter(&match?(%Link{}, &1))
        |> Enum.with_index()
        |> Enum.map(fn {link, position} ->
          %{url: link.url, label: label_of(link), position: position}
        end)

      {:ok, links}
    end
  end

  # A label is inline markdown -- `[**bold**](url)` is a link node holding a
  # strong node holding text -- so the literals are gathered from wherever they
  # sit rather than read off the first child.
  defp label_of(%Link{nodes: nodes}), do: literals(nodes)

  defp literals(nodes) when is_list(nodes), do: Enum.map_join(nodes, &literal/1)

  defp literal(%Text{literal: literal}), do: literal
  defp literal(%MDEx.Code{literal: literal}), do: literal
  defp literal(%{nodes: nodes}) when is_list(nodes), do: literals(nodes)
  defp literal(_node), do: ""

  # Top-level nodes only: a heading nested inside a list item or a block quote
  # belongs to that structure and cutting there would leave both halves invalid.
  defp sections(nodes) do
    nodes
    |> Enum.reduce([], fn
      %Heading{level: level} = heading, sections when level <= @cut_depth ->
        [[heading] | sections]

      node, [] ->
        [[node]]

      node, [current | rest] ->
        [[node | current] | rest]
    end)
    |> Enum.map(&Enum.reverse/1)
    |> Enum.reverse()
  end

  defp render_all(sections, %Document{} = document) do
    sections
    |> Enum.reduce_while({:ok, []}, fn section, {:ok, rendered} ->
      case render(document, section) do
        {:ok, ""} -> {:cont, {:ok, rendered}}
        {:ok, content} -> {:cont, {:ok, [content | rendered]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, rendered} -> {:ok, Enum.reverse(rendered)}
      error -> error
    end
  end

  defp render(%Document{} = document, section) do
    with {:ok, markdown} <- MDEx.to_markdown(%Document{document | nodes: section}, @options) do
      {:ok, String.trim(markdown)}
    end
  end
end
