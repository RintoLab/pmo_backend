defmodule RintoPMO.Attachments.Attachment do
  @moduledoc """
  Metadata for one uploaded image. The bytes live on disk under
  `RintoPMO.Attachments.Storage`; this row is the handle.

  Every field except `filename` is derived from the bytes rather than from the
  request, so nothing here can be asserted by a client.

  `last_used_at` is not cast: it is stamped by
  `RintoPMO.Attachments.touch_attachments/1` when a reference is actually
  expanded into a prompt, never by a caller claiming the image was used.
  """

  use RintoPMO, :schema

  alias RintoPMO.Actors.Actor
  alias RintoPMO.Embeddings

  @type t :: %__MODULE__{}

  schema "attachments" do
    field :filename, :string
    field :mime_type, :string
    field :byte_size, :integer
    field :width, :integer
    field :height, :integer
    field :checksum, :string
    field :last_used_at, :utc_datetime_usec

    # Null means "needs embedding". Never cast from a caller: it is written
    # by the worker that computes it, and voided by whichever changeset rewrites
    # the filename it was made from. See `RintoPMO.Embeddings`.
    field :embedding, Pgvector.Ecto.Vector

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
    |> Embeddings.invalidate([:filename])
  end
end
