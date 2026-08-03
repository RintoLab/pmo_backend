defmodule RintoPMO.Attachments.ImageInfo do
  @moduledoc """
  Identifies an image from its own bytes: format and pixel dimensions.

  The uploader's `Content-Type` is a claim, not evidence, so it is never
  consulted. The recognised set is exactly what pi forwards inline to a model --
  PNG, JPEG, GIF, WebP, the four `pi-ai` accepts as `ImageContent` -- because
  anything else is rejected further down the pipeline anyway, and upload time is
  the only point where a person is still around to read the error.

  Only headers are parsed. A truncated or malformed file fails here rather than
  at the provider.
  """

  import Bitwise, only: [band: 2, bsr: 2]

  @type t :: %{mime_type: String.t(), width: pos_integer(), height: pos_integer()}

  @png_signature <<0x89, "PNG\r\n", 0x1A, "\n">>

  @doc """
  Reads format and dimensions out of `bytes`.

  Returns `{:error, :unsupported_image}` for anything outside the four
  inline-capable formats, and `{:error, :corrupt_image}` when the format is
  recognised but its header carries no usable dimensions.
  """
  @spec inspect_bytes(binary()) :: {:ok, t()} | {:error, :unsupported_image | :corrupt_image}
  def inspect_bytes(<<@png_signature, _length::32, "IHDR", width::32, height::32, _rest::binary>>)
      when width > 0 and height > 0 do
    {:ok, %{mime_type: "image/png", width: width, height: height}}
  end

  def inspect_bytes(<<@png_signature, _rest::binary>>), do: {:error, :corrupt_image}

  def inspect_bytes(<<"GIF8", version, "a", width::little-16, height::little-16, _rest::binary>>)
      when version in [?7, ?9] and width > 0 and height > 0 do
    {:ok, %{mime_type: "image/gif", width: width, height: height}}
  end

  def inspect_bytes(<<"GIF8", _rest::binary>>), do: {:error, :corrupt_image}

  def inspect_bytes(<<0xFF, 0xD8, rest::binary>>) do
    case jpeg_dimensions(rest) do
      {:ok, width, height} -> {:ok, %{mime_type: "image/jpeg", width: width, height: height}}
      :error -> {:error, :corrupt_image}
    end
  end

  def inspect_bytes(<<"RIFF", _size::32, "WEBP", rest::binary>>) do
    case webp_dimensions(rest) do
      {:ok, width, height} -> {:ok, %{mime_type: "image/webp", width: width, height: height}}
      :error -> {:error, :corrupt_image}
    end
  end

  def inspect_bytes(bytes) when is_binary(bytes), do: {:error, :unsupported_image}

  # A JPEG's dimensions live in a start-of-frame segment sitting an arbitrary
  # number of variable-length segments into the file, so the chain has to be
  # walked. 0xC0..0xCF are all frame markers except DHT/JPG/DAC, which share the
  # range without describing a frame.
  defp jpeg_dimensions(<<0xFF, 0xFF, rest::binary>>) do
    # Fill bytes are legal padding ahead of the next marker.
    jpeg_dimensions(<<0xFF, rest::binary>>)
  end

  defp jpeg_dimensions(
         <<0xFF, marker, _length::16, _precision, height::16, width::16, _rest::binary>>
       )
       when marker in 0xC0..0xCF and marker not in [0xC4, 0xC8, 0xCC] and width > 0 and height > 0 do
    {:ok, width, height}
  end

  defp jpeg_dimensions(<<0xFF, marker, rest::binary>>)
       when marker in 0xD0..0xD9 or marker == 0x01 do
    # Standalone markers carry no payload of their own.
    jpeg_dimensions(rest)
  end

  defp jpeg_dimensions(<<0xFF, _marker, length::16, rest::binary>>) when length >= 2 do
    payload = length - 2

    case rest do
      <<_skipped::binary-size(^payload), tail::binary>> -> jpeg_dimensions(tail)
      _too_short -> :error
    end
  end

  defp jpeg_dimensions(_bytes), do: :error

  # WebP has three container flavours, each storing its size differently. Lossy
  # ("VP8 ") keeps 14-bit values behind a start code; lossless ("VP8L") packs
  # both into 28 bits, each minus one; extended ("VP8X") uses 24-bit minus-one
  # values in the header chunk.
  defp webp_dimensions(
         <<"VP8 ", _size::32, _frame_tag::binary-size(3), 0x9D, 0x01, 0x2A, width::little-16,
           height::little-16, _rest::binary>>
       ) do
    ok_dimensions(band(width, 0x3FFF), band(height, 0x3FFF))
  end

  defp webp_dimensions(<<"VP8L", _size::32, 0x2F, bits::little-32, _rest::binary>>) do
    ok_dimensions(band(bits, 0x3FFF) + 1, band(bsr(bits, 14), 0x3FFF) + 1)
  end

  defp webp_dimensions(
         <<"VP8X", _size::32, _flags::binary-size(4), width::little-24, height::little-24,
           _rest::binary>>
       ) do
    ok_dimensions(width + 1, height + 1)
  end

  defp webp_dimensions(_bytes), do: :error

  defp ok_dimensions(width, height) when width > 0 and height > 0, do: {:ok, width, height}
  defp ok_dimensions(_width, _height), do: :error
end
