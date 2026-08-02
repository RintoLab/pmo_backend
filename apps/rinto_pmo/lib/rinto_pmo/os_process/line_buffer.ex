defmodule RintoPMO.OSProcess.LineBuffer do
  @moduledoc """
  Incremental LF line framing for byte streams.

  Splits on `\\n` only, never on `\\r` alone and never on the Unicode line
  separators `U+2028` / `U+2029`, so a frame may safely contain those bytes.
  A trailing `\\r` is stripped from each complete line, making `\\r\\n` input
  transparent. Empty lines are preserved — a blank line is real output.

  Use `split/1` when you already keep the carry buffer yourself, or
  `new/1` + `push/2` + `flush/1` when you want this module to keep it.

  ## Bounding the carry buffer

  A stream that never emits a newline would otherwise grow the carry buffer
  without limit. `new/1` takes a maximum line length: once the pending partial
  line exceeds it, the leading `max_bytes` are emitted as a line of their own
  and buffering continues from there.

  That deliberately cuts a logical line in half, which is lossy — a consumer
  parsing JSONL will see the fragment fail to decode. The alternative is
  unbounded memory growth driven by whatever the child writes, so the cut is
  the safer default whenever the child is not fully trusted to frame its own
  output.
  """

  defstruct rest: "", max_bytes: :infinity

  @type t :: %__MODULE__{rest: binary(), max_bytes: pos_integer() | :infinity}

  @doc """
  Returns an empty buffer, optionally capping the pending partial line.

  ## Examples

      iex> alias RintoPMO.OSProcess.LineBuffer
      iex> {lines, buffer} = LineBuffer.push(LineBuffer.new(4), "abcdefghij")
      iex> {lines, buffer.rest}
      {["abcd", "efgh"], "ij"}
  """
  @spec new(pos_integer() | :infinity) :: t()
  def new(max_bytes \\ :infinity)
  def new(:infinity), do: %__MODULE__{}

  def new(max_bytes) when is_integer(max_bytes) and max_bytes > 0,
    do: %__MODULE__{max_bytes: max_bytes}

  @doc """
  Splits a binary into complete lines plus the trailing partial line.

  ## Examples

      iex> alias RintoPMO.OSProcess.LineBuffer
      iex> LineBuffer.split("a\\nb\\n")
      {["a", "b"], ""}

      iex> alias RintoPMO.OSProcess.LineBuffer
      iex> LineBuffer.split("a\\nb")
      {["a"], "b"}

      iex> alias RintoPMO.OSProcess.LineBuffer
      iex> LineBuffer.split("one\\r\\ntwo\\n")
      {["one", "two"], ""}

      iex> alias RintoPMO.OSProcess.LineBuffer
      iex> LineBuffer.split("a\\n\\nb\\n")
      {["a", "", "b"], ""}

      iex> alias RintoPMO.OSProcess.LineBuffer
      iex> LineBuffer.split("a\\u2028b")
      {[], "a\\u2028b"}
  """
  @spec split(binary()) :: {[binary()], binary()}
  def split(buffer) when is_binary(buffer) do
    case String.split(buffer, "\n") do
      [only] ->
        {[], only}

      many ->
        {complete, [rest]} = Enum.split(many, -1)
        {Enum.map(complete, &strip_trailing_cr/1), rest}
    end
  end

  @doc """
  Appends a chunk and returns any lines it completed.

  ## Examples

      iex> alias RintoPMO.OSProcess.LineBuffer
      iex> {lines, buffer} = LineBuffer.push(LineBuffer.new(), "a\\nb")
      iex> lines
      ["a"]
      iex> {lines, _buffer} = LineBuffer.push(buffer, "c\\n")
      iex> lines
      ["bc"]
  """
  @spec push(t(), binary()) :: {[binary()], t()}
  def push(%__MODULE__{rest: rest, max_bytes: max_bytes}, chunk) when is_binary(chunk) do
    {lines, new_rest} = split(rest <> chunk)
    {fragments, new_rest} = cap_pending(new_rest, max_bytes)
    lines = Enum.flat_map(lines, &cap(&1, max_bytes))

    {lines ++ fragments, %__MODULE__{rest: new_rest, max_bytes: max_bytes}}
  end

  # Complete lines are capped too, not just the pending one: the limit promises
  # a maximum line length, and a single large read can complete an over-long
  # line without it ever having sat in the carry buffer.
  #
  # Fragments are mid-line by construction, so a trailing "\r" is real data
  # here and must not be stripped the way a complete line's is.
  defp cap(binary, :infinity), do: [binary]
  defp cap(binary, max_bytes) when byte_size(binary) <= max_bytes, do: [binary]

  defp cap(binary, max_bytes) do
    <<fragment::binary-size(^max_bytes), rest::binary>> = binary
    [fragment | cap(rest, max_bytes)]
  end

  # Same split, except the final fragment stays in the buffer: it is still
  # under the limit and the next chunk may yet complete it into a real line.
  defp cap_pending(rest, :infinity), do: {[], rest}
  defp cap_pending(rest, max_bytes) when byte_size(rest) <= max_bytes, do: {[], rest}

  defp cap_pending(rest, max_bytes) do
    {fragments, [pending]} = rest |> cap(max_bytes) |> Enum.split(-1)
    {fragments, pending}
  end

  @doc """
  Emits any buffered partial line as a final line and empties the buffer.

  Call this at end of stream so a last line without a trailing `\\n` is not
  silently dropped.

  ## Examples

      iex> alias RintoPMO.OSProcess.LineBuffer
      iex> {_lines, buffer} = LineBuffer.push(LineBuffer.new(), "a\\nb")
      iex> {lines, buffer} = LineBuffer.flush(buffer)
      iex> {lines, buffer.rest}
      {["b"], ""}

      iex> alias RintoPMO.OSProcess.LineBuffer
      iex> {lines, buffer} = LineBuffer.flush(LineBuffer.new())
      iex> {lines, buffer.rest}
      {[], ""}
  """
  @spec flush(t()) :: {[binary()], t()}
  def flush(%__MODULE__{rest: "", max_bytes: max_bytes}),
    do: {[], %__MODULE__{max_bytes: max_bytes}}

  def flush(%__MODULE__{rest: rest, max_bytes: max_bytes}),
    do: {rest |> strip_trailing_cr() |> cap(max_bytes), %__MODULE__{max_bytes: max_bytes}}

  defp strip_trailing_cr(line), do: String.replace_suffix(line, "\r", "")
end
