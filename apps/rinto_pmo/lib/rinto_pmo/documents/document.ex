defmodule RintoPMO.Documents.Document do
  @moduledoc """
  The stable identity of a document.

  Mutable document content and titles live in immutable revisions. Documents
  only carry optional project ownership and their archive lifecycle.
  """

  use RintoPMO, :schema

  alias RintoPMO.Annotations.Annotation
  alias RintoPMO.Documents.BlockProposal
  alias RintoPMO.Documents.DocumentRevision
  alias RintoPMO.Projects.Project

  @type t :: %__MODULE__{}

  schema "documents" do
    field :archived_at, :utc_datetime_usec
    field :latest_revision, :any, virtual: true

    belongs_to :project, Project
    has_many :revisions, DocumentRevision
    has_many :annotations, Annotation
    has_many :proposals, BlockProposal

    timestamps()
  end

  @doc false
  def creation_changeset(%__MODULE__{} = document, attrs) do
    document
    |> cast(nest_initial_revision(attrs), [:project_id])
    |> foreign_key_constraint(:project_id)
    |> cast_assoc(:revisions, with: &DocumentRevision.initial_changeset/2, required: true)
  end

  @doc false
  def archive_changeset(%__MODULE__{archived_at: nil} = document) do
    change(document, archived_at: DateTime.utc_now())
  end

  def archive_changeset(%__MODULE__{} = document), do: change(document)

  defp nest_initial_revision(attrs) when is_map(attrs) do
    attrs = stringify_keys(attrs)

    revision = %{
      "title" => attrs["title"],
      "change_summary" => attrs["change_summary"],
      "source_conversation_id" => attrs["conversation_id"],
      "blocks" => Map.get(attrs, "blocks", [])
    }

    attrs
    |> Map.drop(["title", "change_summary", "conversation_id", "blocks"])
    |> Map.put("revisions", [revision])
  end

  defp stringify_keys(attrs) do
    Map.new(attrs, fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), value}
      {key, value} -> {key, value}
    end)
  end
end
