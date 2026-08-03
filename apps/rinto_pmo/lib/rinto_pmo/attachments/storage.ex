defmodule RintoPMO.Attachments.Storage do
  @moduledoc """
  Where attachment bytes live on disk.

  Files are addressed by attachment id, fanned out one level so a directory
  never accumulates every upload ever made. Addressing by id rather than by
  content hash means deleting a row can delete its file unconditionally -- with
  content addressing the same blob may back several rows, and a delete would
  first have to prove nobody else still points at it.

  Configure the root under `config :rinto_pmo, RintoPMO.Attachments, root: ...`.
  """

  @doc """
  Absolute path of `attachment_id`'s blob. The file need not exist.
  """
  @spec path(UUIDv7.t()) :: String.t()
  def path(attachment_id) when is_binary(attachment_id) do
    Path.join([root(), String.slice(attachment_id, 0, 2), attachment_id])
  end

  @doc """
  Writes `bytes` for `attachment_id`, creating the fan-out directory.
  """
  @spec write(UUIDv7.t(), binary()) :: :ok | {:error, File.posix()}
  def write(attachment_id, bytes) do
    path = path(attachment_id)

    with :ok <- path |> Path.dirname() |> File.mkdir_p() do
      File.write(path, bytes)
    end
  end

  @doc """
  Reads the bytes back.
  """
  @spec read(UUIDv7.t()) :: {:ok, binary()} | {:error, File.posix()}
  def read(attachment_id), do: attachment_id |> path() |> File.read()

  @doc """
  Removes the blob. A file that is already gone is a success: the caller is
  deleting the attachment either way, and a missing blob is the state it wants.
  """
  @spec delete(UUIDv7.t()) :: :ok | {:error, File.posix()}
  def delete(attachment_id) do
    case attachment_id |> path() |> File.rm() do
      {:error, :enoent} -> :ok
      other -> other
    end
  end

  @doc """
  The configured storage root.
  """
  @spec root() :: String.t()
  def root do
    :rinto_pmo
    |> Application.fetch_env!(RintoPMO.Attachments)
    |> Keyword.fetch!(:root)
  end
end
