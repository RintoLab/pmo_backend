defmodule RintoPMO.ImageFixtures do
  @moduledoc """
  Minimal but genuinely valid images, built byte by byte.

  Real encoders are not available in this project, and a fixture file checked
  into the tree tells a reader nothing about *why* the parser accepts it. These
  build the exact header fields `RintoPMO.Attachments.ImageInfo` reads, so a
  test that changes dimensions changes them where they are documented.
  """

  @png_signature <<0x89, "PNG\r\n", 0x1A, "\n">>

  @doc """
  A PNG whose IHDR declares `width` x `height`.
  """
  @spec png(pos_integer(), pos_integer()) :: binary()
  def png(width \\ 1, height \\ 1) do
    ihdr = <<width::32, height::32, 8, 6, 0, 0, 0>>

    @png_signature <>
      chunk("IHDR", ihdr) <>
      chunk("IDAT", <<0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00, 0x05, 0x00, 0x01>>) <>
      chunk("IEND", "")
  end

  @doc """
  A JPEG carrying an APP0 segment ahead of the SOF0 that holds the dimensions,
  so the parser has to walk at least one segment to find them.
  """
  @spec jpeg(pos_integer(), pos_integer()) :: binary()
  def jpeg(width \\ 1, height \\ 1) do
    app0 = <<0xFF, 0xE0, 16::16, "JFIF", 0, 1, 2, 0, 0, 1, 0, 1, 0, 0>>
    sof0 = <<0xFF, 0xC0, 11::16, 8, height::16, width::16, 1, 1, 0x11, 0>>

    <<0xFF, 0xD8>> <> app0 <> sof0 <> <<0xFF, 0xD9>>
  end

  @doc """
  A GIF89a header.
  """
  @spec gif(pos_integer(), pos_integer()) :: binary()
  def gif(width \\ 1, height \\ 1) do
    "GIF89a" <> <<width::little-16, height::little-16, 0x80, 0, 0>>
  end

  @doc """
  A lossy WebP ("VP8 ") header.
  """
  @spec webp(pos_integer(), pos_integer()) :: binary()
  def webp(width \\ 1, height \\ 1) do
    frame = <<0, 0, 0, 0x9D, 0x01, 0x2A, width::little-16, height::little-16>>
    body = "WEBP" <> "VP8 " <> <<byte_size(frame)::32>> <> frame

    "RIFF" <> <<byte_size(body)::32>> <> body
  end

  defp chunk(type, data) do
    <<byte_size(data)::32>> <> type <> data <> <<:erlang.crc32(type <> data)::32>>
  end
end
