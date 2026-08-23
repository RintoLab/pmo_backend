defmodule RintoPMO.Projects.Project do
  @moduledoc """
  A project groups documents, repositories, and the rest of the PMO domain.

  Projects are archived rather than physically deleted.
  """

  use RintoPMO, :schema

  alias RintoPMO.Documents.Document
  alias RintoPMO.Embeddings
  alias RintoPMO.Projects.ProjectRepo

  @type t :: %__MODULE__{}

  schema "projects" do
    field :name, :string
    field :slug, :string
    field :description, :string
    field :status, Ecto.Enum, values: [:active, :archived], default: :active

    # Null means "needs embedding". Never cast from a caller: it is written
    # by the worker that computes it, and voided by whichever changeset rewrites
    # the name and description it was made from. See `RintoPMO.Embeddings`.
    field :embedding, Pgvector.Ecto.Vector

    has_many :repos, ProjectRepo
    has_many :documents, Document

    timestamps()
  end

  @doc false
  def changeset(%__MODULE__{} = project \\ %__MODULE__{}, attrs) do
    project
    |> cast(attrs, [:name, :slug, :description])
    |> validate_required([:name, :slug, :description])
    |> validate_format(:slug, ~r/^[a-z0-9]+(?:-[a-z0-9]+)*$/,
      message: "must contain only lowercase letters, numbers, and hyphens"
    )
    |> unique_constraint(:slug)
    |> Embeddings.invalidate([:name, :description])
  end

  @doc false
  def archive_changeset(%__MODULE__{} = project) do
    change(project, status: :archived)
  end
end
