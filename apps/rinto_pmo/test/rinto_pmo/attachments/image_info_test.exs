defmodule RintoPMO.Attachments.ImageInfoTest do
  use ExUnit.Case, async: true

  alias RintoPMO.Attachments.ImageInfo
  alias RintoPMO.ImageFixtures

  describe "inspect_bytes/1 on supported formats" do
    test "reads PNG dimensions from IHDR" do
      assert {:ok, %{mime_type: "image/png", width: 800, height: 600}} =
               ImageInfo.inspect_bytes(ImageFixtures.png(800, 600))
    end

    test "reads JPEG dimensions from the frame past an earlier segment" do
      assert {:ok, %{mime_type: "image/jpeg", width: 1920, height: 1080}} =
               ImageInfo.inspect_bytes(ImageFixtures.jpeg(1920, 1080))
    end

    test "reads GIF dimensions, which are little-endian" do
      assert {:ok, %{mime_type: "image/gif", width: 320, height: 200}} =
               ImageInfo.inspect_bytes(ImageFixtures.gif(320, 200))
    end

    test "reads lossy WebP dimensions" do
      assert {:ok, %{mime_type: "image/webp", width: 640, height: 480}} =
               ImageInfo.inspect_bytes(ImageFixtures.webp(640, 480))
    end

    test "reads lossless WebP dimensions, which are packed and off by one" do
      # 14 bits of width-1, then 14 bits of height-1.
      bits = 99 + 49 * 0x4000
      body = "WEBP" <> "VP8L" <> <<5::32, 0x2F, bits::little-32>>

      assert {:ok, %{mime_type: "image/webp", width: 100, height: 50}} =
               ImageInfo.inspect_bytes("RIFF" <> <<byte_size(body)::32>> <> body)
    end

    test "reads extended WebP dimensions" do
      body = "WEBP" <> "VP8X" <> <<10::32, 0::32, 799::little-24, 599::little-24>>

      assert {:ok, %{mime_type: "image/webp", width: 800, height: 600}} =
               ImageInfo.inspect_bytes("RIFF" <> <<byte_size(body)::32>> <> body)
    end
  end

  describe "inspect_bytes/1 on rejects" do
    test "refuses a format no provider takes inline, even a real image one" do
      bmp = "BM" <> <<70::little-32, 0::little-32, 54::little-32, 40::little-32>>

      assert {:error, :unsupported_image} = ImageInfo.inspect_bytes(bmp)
    end

    test "refuses a PDF" do
      assert {:error, :unsupported_image} = ImageInfo.inspect_bytes("%PDF-1.7\n%\xE2\xE3\xCF\xD3")
    end

    test "refuses empty input" do
      assert {:error, :unsupported_image} = ImageInfo.inspect_bytes("")
    end

    test "reports a truncated PNG as corrupt rather than unsupported" do
      truncated = ImageFixtures.png() |> binary_part(0, 12)

      assert {:error, :corrupt_image} = ImageInfo.inspect_bytes(truncated)
    end

    test "reports a JPEG with no frame segment as corrupt" do
      assert {:error, :corrupt_image} = ImageInfo.inspect_bytes(<<0xFF, 0xD8, 0xFF, 0xD9>>)
    end

    test "reports a zero-dimension PNG as corrupt" do
      assert {:error, :corrupt_image} = ImageInfo.inspect_bytes(ImageFixtures.png(0, 10))
    end

    test "stops rather than looping on a segment that claims a bogus length" do
      # A length of 0xFFFF with nothing behind it must terminate the walk.
      assert {:error, :corrupt_image} =
               ImageInfo.inspect_bytes(<<0xFF, 0xD8, 0xFF, 0xE0, 0xFF, 0xFF, 0x00>>)
    end
  end
end
