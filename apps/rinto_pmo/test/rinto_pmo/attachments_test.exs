defmodule RintoPMO.AttachmentsTest do
  use RintoPMO.DataCase, async: true

  alias RintoPMO.Attachments
  alias RintoPMO.Attachments.Storage
  alias RintoPMO.ImageFixtures

  setup do
    {:ok, actor: insert(:actor)}
  end

  describe "create_attachment/1" do
    test "records what the bytes are, not what the request claimed", %{actor: actor} do
      bytes = ImageFixtures.png(640, 480)

      assert {:ok, attachment} =
               Attachments.create_attachment(%{
                 "actor_id" => actor.id,
                 "filename" => "screenshot.png",
                 "content" => bytes
               })

      assert attachment.mime_type == "image/png"
      assert attachment.width == 640
      assert attachment.height == 480
      assert attachment.byte_size == byte_size(bytes)
      assert attachment.filename == "screenshot.png"
    end

    test "ignores a lying filename extension", %{actor: actor} do
      assert {:ok, attachment} =
               Attachments.create_attachment(%{
                 "actor_id" => actor.id,
                 "filename" => "definitely.png",
                 "content" => ImageFixtures.jpeg(10, 10)
               })

      assert attachment.mime_type == "image/jpeg"
    end

    test "writes the bytes where the id says they are", %{actor: actor} do
      bytes = ImageFixtures.png()

      assert {:ok, attachment} =
               Attachments.create_attachment(%{"actor_id" => actor.id, "content" => bytes})

      assert File.read!(Storage.path(attachment.id)) == bytes
    end

    test "accepts a file on disk, which is what an upload gives us", %{actor: actor} do
      path =
        Path.join(System.tmp_dir!(), "attachment-source-#{System.unique_integer([:positive])}")

      File.write!(path, ImageFixtures.gif(8, 8))
      on_exit(fn -> File.rm(path) end)

      assert {:ok, attachment} =
               Attachments.create_attachment(%{"actor_id" => actor.id, "path" => path})

      assert attachment.mime_type == "image/gif"
      assert attachment.width == 8
    end

    test "rejects a format no provider takes inline", %{actor: actor} do
      assert {:error, :unsupported_image, details} =
               Attachments.create_attachment(%{"actor_id" => actor.id, "content" => "%PDF-1.7"})

      assert "image/png" in details["supported"]
    end

    test "rejects bytes over the inline size cap", %{actor: actor} do
      oversize = ImageFixtures.png() <> :binary.copy("x", Attachments.max_bytes())

      assert {:error, :image_too_large, details} =
               Attachments.create_attachment(%{"actor_id" => actor.id, "content" => oversize})

      assert details["limit"] == Attachments.max_bytes()
    end

    test "rejects an image past the dimension cap", %{actor: actor} do
      too_wide = Attachments.max_dimension() + 1

      assert {:error, :image_too_large, details} =
               Attachments.create_attachment(%{
                 "actor_id" => actor.id,
                 "content" => ImageFixtures.png(too_wide, 10)
               })

      assert details["width"] == too_wide
    end

    test "leaves no bytes behind when the row is rejected" do
      # Dimensions no other test uses, so these bytes are unique in a storage
      # root that async tests share.
      bytes = ImageFixtures.png(1234, 567)

      assert {:error, changeset} =
               Attachments.create_attachment(%{"actor_id" => nil, "content" => bytes})

      assert %{actor_id: ["can't be blank"]} = errors_on(changeset)
      refute stored?(bytes)
    end

    test "reports a missing source rather than storing an empty file", %{actor: actor} do
      assert {:error, :bad_request, _details} =
               Attachments.create_attachment(%{"actor_id" => actor.id})
    end
  end

  describe "image_content/1" do
    test "produces exactly the shape pi's RpcCommand takes", %{actor: actor} do
      bytes = ImageFixtures.png()

      {:ok, attachment} =
        Attachments.create_attachment(%{"actor_id" => actor.id, "content" => bytes})

      assert {:ok, content} = Attachments.image_content(attachment)

      assert content == %{
               "type" => "image",
               "mimeType" => "image/png",
               "data" => Base.encode64(bytes)
             }
    end

    test "reports missing bytes instead of handing pi an empty image", %{actor: actor} do
      {:ok, attachment} =
        Attachments.create_attachment(%{"actor_id" => actor.id, "content" => ImageFixtures.png()})

      File.rm!(Storage.path(attachment.id))

      assert {:error, :attachment_unreadable, _details} = Attachments.image_content(attachment)
    end
  end

  describe "touch_attachments/1" do
    test "stamps every id in one go", %{actor: actor} do
      one = insert(:attachment, actor: actor)
      two = insert(:attachment, actor: actor)

      assert is_nil(one.last_used_at)

      assert :ok = Attachments.touch_attachments([one.id, two.id])

      assert %{last_used_at: %DateTime{}} = Attachments.get_attachment!(one.id)
      assert %{last_used_at: %DateTime{}} = Attachments.get_attachment!(two.id)
    end

    test "leaves updated_at alone, because being used is not an edit", %{actor: actor} do
      attachment = insert(:attachment, actor: actor)

      assert :ok = Attachments.touch_attachments([attachment.id])

      assert Attachments.get_attachment!(attachment.id).updated_at == attachment.updated_at
    end

    test "moves the stamp forward on a later use", %{actor: actor} do
      attachment = insert(:attachment, actor: actor)

      :ok = Attachments.touch_attachments([attachment.id])
      first = Attachments.get_attachment!(attachment.id).last_used_at

      :ok = Attachments.touch_attachments([attachment.id])
      second = Attachments.get_attachment!(attachment.id).last_used_at

      assert DateTime.compare(second, first) in [:gt, :eq]
    end

    test "an empty list is a no-op rather than a query" do
      assert :ok = Attachments.touch_attachments([])
    end

    test "an id that no longer exists is not an error" do
      assert :ok = Attachments.touch_attachments([UUIDv7.generate()])
    end
  end

  describe "delete_attachment/1" do
    test "removes the row and the bytes", %{actor: actor} do
      {:ok, attachment} =
        Attachments.create_attachment(%{"actor_id" => actor.id, "content" => ImageFixtures.png()})

      assert {:ok, _deleted} = Attachments.delete_attachment(attachment)
      refute File.exists?(Storage.path(attachment.id))

      assert_raise Ecto.NoResultsError, fn -> Attachments.get_attachment!(attachment.id) end
    end
  end

  defp stored?(bytes) do
    Storage.root()
    |> Path.join("**/*")
    |> Path.wildcard()
    |> Enum.filter(&File.regular?/1)
    |> Enum.any?(&(File.read!(&1) == bytes))
  end
end
