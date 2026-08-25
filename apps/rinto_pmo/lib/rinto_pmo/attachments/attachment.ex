defmodule RintoPMO.Attachments.Attachment do
  @moduledoc """
  Metadata for one uploaded image. The bytes live on disk under
  `RintoPMO.Attachments.Storage`; this row is the handle.

  Every field except `filename` is derived from the bytes rather than from the
  request, so nothing here can be asserted by a client.

  `last_used_at` is not cast: it is stamped by
  `RintoPMO.Attachments.touch_attachments/1` when a reference is actually
  expanded into a prompt, never by a caller claiming the image was used.

  ## No embedding

  An attachment's only text is its filename. Embedding that would be the thing
  the embeddings migration refuses to do for a document title -- spending a
  1024-dimension vector, and a network call to make it, on a handful of
  characters -- except worse: a title is written to describe the thing, while
  `screenshot-2026-08-23.png` was written by a camera. The nearest neighbours
  of such a vector are other filenames that look like it, which is not what
  anybody was asking for.

  So an attachment is not searchable. It stays linkable and expandable, and is
  reached the way it is actually reached: through the body that mentions it.
  """

  use RintoPMO, :schema

  alias RintoPMO.Actors.Actor

  @type t :: %__MODULE__{}

  schema "attachments" do
    field :filename, :string
    field :mime_type, :string
    field :byte_size, :integer
    field :width, :integer
    field :height, :integer
    field :checksum, :string
    field :last_used_at, :utc_datetime_usec

    belongs_to :actor, Actor

    timestamps()
  end

  @doc false
  def changeset(%__MODULE__{} = attachment \\ %__MODULE__{}, attrs) do
    attachment
    |> cast(attrs, [
      :actor_id,
      :filename,
      :mime_type,
      :byte_size,
      :width,
      :height,
      :checksum
    ])
    |> validate_required([:actor_id, :mime_type, :byte_size, :width, :height, :checksum])
    |> validate_number(:byte_size, greater_than: 0)
    |> validate_number(:width, greater_than: 0)
    |> validate_number(:height, greater_than: 0)
    |> foreign_key_constraint(:actor_id)
  end
end
