defmodule RintoPMO.OSProcess.LineBufferTest do
  use ExUnit.Case, async: true

  alias RintoPMO.OSProcess.LineBuffer

  doctest RintoPMO.OSProcess.LineBuffer

  describe "split/1" do
    test "splits complete lines and keeps a partial trailing frame" do
      buffer = Enum.join([~s({"a":1}), ~s({"b":2}), ~s({"c":)], "\n")

      assert {[~s({"a":1}), ~s({"b":2})], ~s({"c":)} = LineBuffer.split(buffer)
    end

    test "strips a trailing carriage return from each complete line" do
      assert {["one", "two"], ""} = LineBuffer.split("one\r\ntwo\n")
    end

    test "does not split on unicode line separators" do
      assert {[], "a\u2028b"} = LineBuffer.split("a\u2028b")
      assert {["a\u2029b"], ""} = LineBuffer.split("a\u2029b\n")
    end

    test "preserves empty lines" do
      assert {["a", "", "b"], ""} = LineBuffer.split("a\n\nb\n")
      assert {["", ""], ""} = LineBuffer.split("\n\n")
    end

    test "returns no lines for input without a newline" do
      assert {[], ""} = LineBuffer.split("")
      assert {[], "partial"} = LineBuffer.split("partial")
    end
  end

  describe "push/2" do
    test "reassembles a line split across chunk boundaries" do
      buffer = LineBuffer.new()

      assert {[], buffer} = LineBuffer.push(buffer, ~s({"a":))
      assert {[], buffer} = LineBuffer.push(buffer, "1")
      assert {[~s({"a":1})], buffer} = LineBuffer.push(buffer, "}\n")
      assert buffer.rest == ""
    end

    test "emits several lines from a single chunk" do
      assert {["a", "b", "c"], buffer} = LineBuffer.push(LineBuffer.new(), "a\nb\nc\nd")
      assert buffer.rest == "d"
    end

    test "handles a chunk that ends exactly on a boundary" do
      assert {["a"], buffer} = LineBuffer.push(LineBuffer.new(), "a\n")
      assert buffer.rest == ""
    end
  end

  describe "flush/1" do
    test "emits the buffered partial line" do
      {[], buffer} = LineBuffer.push(LineBuffer.new(), "trailing")

      assert {["trailing"], buffer} = LineBuffer.flush(buffer)
      assert buffer.rest == ""
    end

    test "strips a trailing carriage return from the flushed line" do
      {[], buffer} = LineBuffer.push(LineBuffer.new(), "trailing\r")

      assert {["trailing"], _buffer} = LineBuffer.flush(buffer)
    end

    test "emits nothing when the buffer is empty" do
      assert {[], _buffer} = LineBuffer.flush(LineBuffer.new())
    end

    test "caps the flushed line" do
      {_lines, buffer} = LineBuffer.push(LineBuffer.new(3), "abcde")

      assert {["de"], _buffer} = LineBuffer.flush(buffer)
    end
  end

  describe "max_bytes" do
    test "keeps the carry buffer bounded when no newline ever arrives" do
      buffer =
        Enum.reduce(1..100, LineBuffer.new(8), fn _i, buffer ->
          {_lines, buffer} = LineBuffer.push(buffer, "0123456789")
          buffer
        end)

      assert byte_size(buffer.rest) <= 8
    end

    test "emits the overflow as fragments instead of buffering it" do
      assert {["abcd", "efgh"], buffer} = LineBuffer.push(LineBuffer.new(4), "abcdefghij")
      assert buffer.rest == "ij"
    end

    test "caps a complete line that arrived whole in one chunk" do
      assert {["aaaa", "aaaa", "aa"], buffer} =
               LineBuffer.push(LineBuffer.new(4), "aaaaaaaaaa\n")

      assert buffer.rest == ""
    end

    test "leaves a line exactly at the limit intact" do
      assert {["abcd"], _buffer} = LineBuffer.push(LineBuffer.new(4), "abcd\n")
    end

    test "keeps a pending line exactly at the limit, which may still complete" do
      assert {[], buffer} = LineBuffer.push(LineBuffer.new(4), "abcd")
      assert buffer.rest == "abcd"
      assert {["abcd"], _buffer} = LineBuffer.push(buffer, "\n")
    end

    test "does not strip a carriage return from a mid-line fragment" do
      assert {["ab\r"], _buffer} = LineBuffer.push(LineBuffer.new(3), "ab\rcd")
    end

    test "is unbounded by default" do
      long = String.duplicate("x", 10_000)

      assert {[], buffer} = LineBuffer.push(LineBuffer.new(), long)
      assert byte_size(buffer.rest) == 10_000
    end
  end
end
