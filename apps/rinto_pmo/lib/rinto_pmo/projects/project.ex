defmodule RintoPMO.Projects.Project do
  @moduledoc """
  A project groups documents, repositories, and the rest of the PMO domain.

  Projects are archived rather than physically deleted.

  ## The slug is chosen once

  `rinto://project/{slug}` is the one address in this system that names a thing
  by something other than its id, and a body carries that address as written.
  Renaming a slug would leave every `rinto://project/old-slug` already written
  into a document pointing at nothing -- and `mix rinto.index.rebuild` could not
  repair it, because it reads the same stale string back out of the same bodies
  it would be rebuilding from. `RintoPMO.Search` makes it worse by spreading
  them: a project hit answers with that URI, for a model to paste into prose.

  So `update_changeset/2` does not cast `:slug`; only `create_changeset/1`
  does. The cost is real and deliberate -- a slug chosen badly is chosen badly
  for good -- and it is paid once, at creation, where it is visible, rather
  than silently later where nothing is watching.

  The name is what a rename is for, and it stays free to change.
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
  def create_changeset(attrs) do
    %__MODULE__{}
    |> cast(attrs, [:name, :slug, :description])
    |> validate_required([:name, :slug, :description])
    |> validate_format(:slug, ~r/^[a-z0-9]+(?:-[a-z0-9]+)*$/,
      message: "must contain only lowercase letters, numbers, and hyphens"
    )
    |> unique_constraint(:slug)
    |> Embeddings.invalidate([:name, :description])
  end

  @doc false
  def update_changeset(%__MODULE__{} = project, attrs) do
    project
    |> cast(attrs, [:name, :description])
    |> validate_required([:name, :description])
    |> refuse_slug_change(attrs)
    |> Embeddings.invalidate([:name, :description])
  end

  # A slug in the payload is refused, not dropped. Leaving it out of `cast/3`
  # is already enough to make the change impossible, but a client that asked
  # for a rename would then get 200 and its old slug back -- an answer that
  # looks like the rename happened. Sending the slug it already has is not a
  # rename and passes.
  defp refuse_slug_change(changeset, attrs) do
    with {:ok, slug} <- fetch_attr(attrs, :slug),
         true <- slug != changeset.data.slug do
      add_error(changeset, :slug, "cannot be changed after the project is created")
    else
      _unchanged -> changeset
    end
  end

  defp fetch_attr(attrs, key) when is_map(attrs) do
    case Map.fetch(attrs, key) do
      {:ok, value} -> {:ok, value}
      :error -> Map.fetch(attrs, Atom.to_string(key))
    end
  end

  defp fetch_attr(_attrs, _key), do: :error

  @doc false
  def archive_changeset(%__MODULE__{} = project) do
    change(project, status: :archived)
  end
end
