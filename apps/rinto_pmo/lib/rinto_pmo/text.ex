defmodule RintoPMO.Text do
  @moduledoc """
  Two things done to a block of prose before it is shown to somebody.

  Both existed in three copies, which is two more than a rule about how text is
  shortened deserves. How *much* is still each caller's decision -- a backlink
  list wants less than a hover card, which wants less than a search result --
  so the limit is a parameter and only the rule is shared.
  """

  @doc """
  Shortens `text` to `limit` characters, marking that it was cut.

  Counts characters rather than bytes: a limit in bytes would cut a Chinese
  document to a third of what the same limit gives an English one, and could
  cut it mid-character.
  """
  @spec excerpt(String.t() | nil, pos_integer()) :: String.t() | nil
  def excerpt(nil, _limit), do: nil

  def excerpt(text, limit) when is_binary(text) do
    case String.trim(text) do
      "" -> nil
      trimmed when byte_size(trimmed) > 0 -> truncate(trimmed, limit)
    end
  end

  @doc """
  The heading a block opens with, as a plain phrase.

  A block has no title of its own -- `RintoPMO.Documents.Markdown` cuts at
  headings, so the first line usually is one. Falling back to that line
  whatever it is keeps a block that opens with prose from being nameless in a
  list.
  """
  @spec heading(String.t() | nil) :: String.t() | nil
  def heading(content) when is_binary(content) do
    content
    |> String.split("\n", parts: 2)
    |> List.first()
    |> String.trim()
    |> String.replace(~r/^#+\s*/, "")
    |> case do
      "" -> nil
      heading -> heading
    end
  end

  def heading(_content), do: nil

  defp truncate(text, limit) do
    if String.length(text) > limit, do: String.slice(text, 0, limit) <> "…", else: text
  end
end
