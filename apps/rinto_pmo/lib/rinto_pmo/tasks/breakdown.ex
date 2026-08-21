defmodule RintoPMO.Tasks.Breakdown do
  @moduledoc """
  Reads a task document's blocks as a work breakdown.

  Pure: blocks in, a shape describing what to create out. Nothing here touches
  the database, because what a document says and what gets filed from it are
  two questions and only the first one has rules worth testing on their own.

  ## The shape it reads

      ## 灰度发布            a chunk of work
      ### 接入十分之一流量    a task in that chunk
      ### 加监控看板          another
      ## 把回滚做成一个开关    a chunk that is one task, with no `###` under it

  A chunk with tasks under it becomes a summary node covering them. A chunk
  with none is a single piece of work and becomes one task, said that way
  rather than left for this module to infer from a summary and a task that
  happen to share a title.

  Everything under either heading is that node's description, acceptance
  criteria included. There is no marker separating criteria from anything else,
  because there is nothing to separate them from: what gets written under a
  task is description, and what would have been a smaller task is written as
  another `###`.

  ## Why this lines up with one block each

  `RintoPMO.Documents.Markdown` cuts at every heading, so each `##` and each
  `###` already arrives as its own block. That is the point rather than an
  obstacle: annotations, proposals and contention anchor on blocks, so one task
  per block is one task a person can argue with. This module therefore reads
  the block sequence rather than re-parsing the document, and the grain it gets
  is the grain the review machinery already works at.

  ## Titles come from the AST

  Not from the block's first line. Block bodies are Markdown rendered back from
  a parse, so a title containing `_` arrives written `annotation\\_replies` --
  correct Markdown, and wrong in a `tasks.title` column. The heading node's
  text has no escaping in it.

  Descriptions do come from the text, kept exactly as the block stores them:
  they stay Markdown and are rendered as Markdown, so the escaping is right
  there and re-rendering would only risk changing it.
  """

  alias RintoPMO.Documents.DocumentBlock

  @typedoc "One task to create."
  @type task :: %{title: String.t(), description: String.t() | nil}

  @typedoc """
  One chunk. With `tasks`, a summary covering them; without, a single task.
  """
  @type chunk :: %{title: String.t(), description: String.t() | nil, tasks: [task()]}

  @doc """
  Reads blocks as chunks, or says why it cannot.

  Refuses two shapes, both of which mean the document is not a breakdown:

    * `:no_chunks` -- nothing to file. An empty document, or one with no
      headings at all
    * `:task_before_chunk` -- a `###` standing above the first `##`. Every task
      belongs to a chunk; one that does not is a document somebody is midway
      through restructuring, and guessing a chunk for it would file work under
      a heading nobody wrote

  Anything before the first heading is a preamble and is ignored. A person is
  free to write a sentence at the top of a breakdown saying what it is.
  """
  @spec parse([DocumentBlock.t()]) :: {:ok, [chunk()]} | {:error, atom(), map()}
  def parse(blocks) when is_list(blocks) do
    blocks
    |> Enum.map(&read/1)
    |> assemble([])
  end

  defp assemble([], []), do: {:error, :no_chunks, %{}}
  defp assemble([], chunks), do: {:ok, Enum.reverse(chunks)}

  # Before the first heading, and only there: `Markdown.split/1` cuts at
  # headings, so every block after the first starts with one.
  defp assemble([:preamble | rest], chunks), do: assemble(rest, chunks)

  defp assemble([{2, title, description} | rest], chunks) do
    assemble(rest, [%{title: title, description: description, tasks: []} | chunks])
  end

  defp assemble([{3, _title, _description} | _rest], []) do
    {:error, :task_before_chunk, %{}}
  end

  defp assemble([{3, title, description} | rest], [chunk | chunks]) do
    task = %{title: title, description: description}
    assemble(rest, [%{chunk | tasks: chunk.tasks ++ [task]} | chunks])
  end

  # `####` and deeper never reach here: `Markdown.split/1` leaves them inside
  # their parent's block, where they read as part of its description.
  defp read(%DocumentBlock{content: content}) do
    case MDEx.parse_document(content) do
      {:ok, %MDEx.Document{nodes: [%MDEx.Heading{level: level} = heading | _rest]}}
      when level in [2, 3] ->
        {level, heading_text(heading), description(content)}

      _not_a_chunk_or_task ->
        :preamble
    end
  end

  defp heading_text(%MDEx.Heading{nodes: nodes}) do
    nodes |> Enum.map_join(&literal/1) |> String.trim()
  end

  # Inline code and emphasis are ordinary in a title -- `### get_blocks 读语义`
  # -- and what is wanted from all of them is the words.
  defp literal(%{literal: literal}) when is_binary(literal), do: literal
  defp literal(%{nodes: nodes}) when is_list(nodes), do: Enum.map_join(nodes, &literal/1)
  defp literal(_node_carrying_no_text), do: ""

  # The block minus its heading. ATX headings are one line, and the block is
  # already normalised Markdown, so this is a cut rather than a re-render.
  defp description(content) do
    case content |> String.split("\n", parts: 2) |> Enum.at(1) do
      nil -> nil
      rest -> rest |> String.trim() |> presence()
    end
  end

  defp presence(""), do: nil
  defp presence(text), do: text
end
