defmodule RintoPMO.Attachments do
  @moduledoc """
  The context for uploaded images.

  An attachment is validated and identified **once, at upload**: format sniffed
  from the bytes, dimensions read, size capped. Every later use -- notably
  expanding a chat reference into a pi `ImageContent` -- is then a plain file
  read, because the expensive and failure-prone half already happened while a
  human was still watching.

  The caps mirror what pi will actually forward. pi normalises images on its
  `@file` path (`cli/file-processor.js`) but **not** on the RPC path, which
  hands `images` straight to the provider, so an image that is too large or in
  the wrong format has to be stopped here or it fails at the model instead.
  """

  use RintoPMO, :context

  alias RintoPMO.Attachments.Attachment
  alias RintoPMO.Attachments.ImageInfo
  alias RintoPMO.Attachments.Storage

  defmodule Behaviour do
    @moduledoc false

    alias RintoPMO.Attachments.Attachment

    @type image_content :: %{
            required(String.t()) => String.t()
          }

    @callback create_attachment(map()) ::
                {:ok, Attachment.t()} | {:error, Ecto.Changeset.t()} | {:error, atom(), map()}
    @callback get_attachment!(UUIDv7.t()) :: Attachment.t()
    @callback touch_attachments([UUIDv7.t()]) :: :ok
    @callback delete_attachment(Attachment.t()) ::
                {:ok, Attachment.t()} | {:error, Ecto.Changeset.t()}
    @callback read_attachment(Attachment.t()) :: {:ok, binary()} | {:error, atom(), map()}
    @callback image_content(Attachment.t()) :: {:ok, image_content()} | {:error, atom(), map()}
  end

  @behaviour Behaviour

  @doc """
  Stores an upload and records what it turned out to be.

  `attrs` carries `actor_id`, an optional `filename`, and the bytes as either
  `path` (a file already on disk, which is what a multipart upload gives us) or
  `content`.

  The row is written only after the bytes are safely on disk, so a failed write
  leaves no attachment pointing at nothing. The reverse -- bytes with no row --
  is possible and harmless: they are unreferenced and collectable.
  """
  @impl true
  def create_attachment(attrs) when is_map(attrs) do
    with {:ok, bytes} <- source_bytes(attrs),
         :ok <- validate_size(byte_size(bytes)),
         {:ok, info} <- inspect_image(bytes),
         :ok <- validate_dimensions(info) do
      insert_attachment(attrs, bytes, info)
    end
  end

  @doc """
  Fetches an attachment's metadata.
  """
  @impl true
  def get_attachment!(id), do: Repo.get!(Attachment, id)

  @doc """
  Records that these attachments were just expanded into a prompt.

  Recording only -- nothing deletes on the strength of this column yet. It
  exists because the question a retention policy has to answer, "is anyone
  still using this?", is otherwise unanswerable here: chat messages are not
  persisted, so there is no reference to count. A stamp at the moment of use is
  the one signal available without that.

  `updated_at` is deliberately left alone. Being sent to an agent is not an
  edit of the attachment, and collapsing the two would destroy the distinction
  the moment either is wanted.
  """
  @impl true
  def touch_attachments([]), do: :ok

  def touch_attachments(ids) when is_list(ids) do
    now = DateTime.utc_now()

    Attachment
    |> where([attachment], attachment.id in ^ids)
    |> Repo.update_all(set: [last_used_at: now])

    :ok
  end

  @doc """
  Deletes the row and its bytes.

  The blob goes after the row so a crash in between leaves an orphaned file
  rather than a row whose bytes have vanished.
  """
  @impl true
  def delete_attachment(%Attachment{} = attachment) do
    with {:ok, deleted} <- Repo.delete(attachment) do
      _ = Storage.delete(attachment.id)
      {:ok, deleted}
    end
  end

  @doc """
  Reads an attachment's raw bytes.
  """
  @impl true
  def read_attachment(%Attachment{} = attachment) do
    case Storage.read(attachment.id) do
      {:ok, bytes} -> {:ok, bytes}
      {:error, reason} -> {:error, :attachment_unreadable, %{"reason" => to_string(reason)}}
    end
  end

  @doc """
  Renders an attachment as pi's `ImageContent`: base64 payload plus mime type.

  Encoding on every use rather than caching the base64 form is deliberate. The
  costly part of an image pipeline is decode/resize/re-encode, and that is
  already spent at upload; a read plus `Base.encode64/1` is noise next to the
  model turn it is feeding.
  """
  @impl true
  def image_content(%Attachment{} = attachment) do
    with {:ok, bytes} <- read_attachment(attachment) do
      {:ok,
       %{
         "type" => "image",
         "mimeType" => attachment.mime_type,
         "data" => Base.encode64(bytes)
       }}
    end
  end

  @doc """
  The largest upload accepted, in bytes.
  """
  @spec max_bytes() :: pos_integer()
  def max_bytes, do: setting(:max_bytes)

  @doc """
  The largest edge length accepted, in pixels.
  """
  @spec max_dimension() :: pos_integer()
  def max_dimension, do: setting(:max_dimension)

  defp source_bytes(%{content: content}) when is_binary(content), do: {:ok, content}
  defp source_bytes(%{"content" => content}) when is_binary(content), do: {:ok, content}
  defp source_bytes(%{path: path}) when is_binary(path), do: read_source(path)
  defp source_bytes(%{"path" => path}) when is_binary(path), do: read_source(path)
  defp source_bytes(_attrs), do: {:error, :bad_request, %{"content" => ["is missing"]}}

  # Stat first: an oversize upload should be rejected on its recorded size, not
  # after being pulled into memory to be measured.
  defp read_source(path) do
    with {:ok, %File.Stat{size: size}} <- File.stat(path),
         :ok <- validate_size(size),
         {:ok, bytes} <- File.read(path) do
      {:ok, bytes}
    else
      {:error, :image_too_large, details} -> {:error, :image_too_large, details}
      {:error, reason} -> {:error, :bad_request, %{"content" => [to_string(reason)]}}
    end
  end

  defp validate_size(size) when is_integer(size) do
    limit = max_bytes()

    if size > limit do
      {:error, :image_too_large, %{"byte_size" => size, "limit" => limit}}
    else
      :ok
    end
  end

  defp inspect_image(bytes) do
    case ImageInfo.inspect_bytes(bytes) do
      {:ok, info} ->
        {:ok, info}

      {:error, :unsupported_image} ->
        {:error, :unsupported_image, %{"supported" => supported_mime_types()}}

      {:error, :corrupt_image} ->
        {:error, :corrupt_image, %{}}
    end
  end

  defp validate_dimensions(%{width: width, height: height}) do
    limit = max_dimension()

    if width > limit or height > limit do
      {:error, :image_too_large, %{"width" => width, "height" => height, "limit" => limit}}
    else
      :ok
    end
  end

  defp insert_attachment(attrs, bytes, info) do
    id = UUIDv7.generate()

    changeset =
      Attachment.changeset(%Attachment{id: id}, %{
        actor_id: attr(attrs, :actor_id),
        filename: attr(attrs, :filename),
        mime_type: info.mime_type,
        byte_size: byte_size(bytes),
        width: info.width,
        height: info.height,
        checksum: :sha256 |> :crypto.hash(bytes) |> Base.encode16(case: :lower)
      })

    if changeset.valid? do
      write_then_insert(id, bytes, changeset)
    else
      {:error, changeset}
    end
  end

  defp write_then_insert(id, bytes, changeset) do
    case Storage.write(id, bytes) do
      :ok ->
        case Repo.insert(changeset) do
          {:ok, attachment} ->
            {:ok, attachment}

          {:error, failed} ->
            _ = Storage.delete(id)
            {:error, failed}
        end

      {:error, reason} ->
        {:error, :attachment_unwritable, %{"reason" => to_string(reason)}}
    end
  end

  defp supported_mime_types, do: ~w(image/png image/jpeg image/gif image/webp)

  defp attr(attrs, key) do
    Map.get(attrs, key) || Map.get(attrs, Atom.to_string(key))
  end

  defp setting(key) do
    :rinto_pmo
    |> Application.fetch_env!(__MODULE__)
    |> Keyword.fetch!(key)
  end
end
