defmodule RintoPMOWeb.V1.AttachmentControllerTest do
  use RintoPMOWeb.ConnCase, async: true

  alias Plug.Upload
  alias RintoPMO.AttachmentsMock
  alias RintoPMO.ImageFixtures

  # The uploader is whoever the token belongs to, so the case's own actor is
  # the one every upload here is credited to.
  setup %{current_actor: actor} do
    {:ok, actor: actor}
  end

  describe "POST /attachments" do
    test "credits the upload to the token holder", %{conn: conn, actor: actor} do
      attachment = insert(:attachment, actor: actor, width: 640, height: 480)
      attachment_id = attachment.id

      expect(AttachmentsMock, :create_attachment, fn attrs ->
        assert attrs["actor_id"] == actor.id
        assert attrs["filename"] == "screenshot.png"
        assert File.read!(attrs["path"]) == ImageFixtures.png(640, 480)
        {:ok, attachment}
      end)

      conn =
        post(conn, ~p"/api/v1/attachments", %{
          "file" => upload("screenshot.png", ImageFixtures.png(640, 480))
        })

      assert %{
               "id" => ^attachment_id,
               "mime_type" => "image/png",
               "width" => 640,
               "height" => 480
             } = json_response(conn, 201)["data"]
    end

    test "rejects a request with no file", %{conn: conn} do
      conn = post(conn, ~p"/api/v1/attachments", %{})

      assert json_response(conn, 400)["error"] == "bad_request"
    end

    test "reports an unsupported format as 415", %{conn: conn} do
      expect(AttachmentsMock, :create_attachment, fn _attrs ->
        {:error, :unsupported_image, %{"supported" => ["image/png"]}}
      end)

      conn =
        post(conn, ~p"/api/v1/attachments", %{
          "file" => upload("notes.pdf", "%PDF-1.7")
        })

      assert json_response(conn, 415)["error"] == "unsupported_image"
    end

    test "reports an oversize image as 413", %{conn: conn} do
      expect(AttachmentsMock, :create_attachment, fn _attrs ->
        {:error, :image_too_large, %{"limit" => 4_500_000}}
      end)

      conn =
        post(conn, ~p"/api/v1/attachments", %{
          "file" => upload("huge.png", ImageFixtures.png())
        })

      assert json_response(conn, 413)["details"]["limit"] == 4_500_000
    end
  end

  describe "GET /attachments/:id" do
    test "returns metadata without the bytes", %{conn: conn} do
      attachment = insert(:attachment)

      expect(AttachmentsMock, :get_attachment!, fn _id -> attachment end)

      conn = get(conn, ~p"/api/v1/attachments/#{attachment.id}")
      data = json_response(conn, 200)["data"]

      assert data["mime_type"] == "image/png"
      refute Map.has_key?(data, "data")
    end
  end

  describe "GET /attachments/:id/content" do
    # The client uploaded the bytes but does not keep them: after a reload the
    # transcript has ids and still has to render the picture.
    test "serves the bytes inline for a browser to render", %{conn: conn} do
      attachment = insert(:attachment, filename: "chart.png")
      bytes = ImageFixtures.png()

      expect(AttachmentsMock, :get_attachment!, fn _id -> attachment end)
      expect(AttachmentsMock, :read_attachment, fn ^attachment -> {:ok, bytes} end)

      conn = get(conn, ~p"/api/v1/attachments/#{attachment.id}/content")

      assert response(conn, 200) == bytes
      assert get_resp_header(conn, "content-type") == ["image/png; charset=utf-8"]
      assert get_resp_header(conn, "content-disposition") == [~s(inline; filename="chart.png")]
    end

    test "reports missing bytes as a server error, not an empty image", %{conn: conn} do
      attachment = insert(:attachment)

      expect(AttachmentsMock, :get_attachment!, fn _id -> attachment end)

      expect(AttachmentsMock, :read_attachment, fn _attachment ->
        {:error, :attachment_unreadable, %{"reason" => "enoent"}}
      end)

      conn = get(conn, ~p"/api/v1/attachments/#{attachment.id}/content")

      assert json_response(conn, 500)["error"] == "attachment_unreadable"
    end
  end

  describe "DELETE /attachments/:id" do
    test "removes the attachment", %{conn: conn} do
      attachment = insert(:attachment)

      expect(AttachmentsMock, :get_attachment!, fn _id -> attachment end)
      expect(AttachmentsMock, :delete_attachment, fn ^attachment -> {:ok, attachment} end)

      conn = delete(conn, ~p"/api/v1/attachments/#{attachment.id}")

      assert response(conn, 204) == ""
    end
  end

  defp upload(filename, content) do
    path = Path.join(System.tmp_dir!(), "upload-#{System.unique_integer([:positive])}")
    File.write!(path, content)
    on_exit(fn -> File.rm(path) end)

    %Upload{path: path, filename: filename, content_type: "application/octet-stream"}
  end
end
