defmodule RintoPMO.Documents.Document do
  @moduledoc """
  The stable identity of a document.

  Mutable document content and titles live in immutable revisions. Documents
  only carry optional project ownership, their archive lifecycle, and how far
  along their status is.

  ## Status

  The question `status` answers is **whether anything downstream may still
  consume this document**:

    * `:draft` -- nobody has vouched for it yet, so nothing may
    * `:formal` -- somebody has, so the things that consume documents may
    * `:applied` -- already consumed once, and once is all there is

  Every document starts `:draft`. Writing something down is not the same as
  vouching for it, and the state records only that nobody has vouched yet --
  the document itself is ordinary, with a real revision history from its first
  revision on.

  `:formal` is a **finished state, not a waiting room.** Most documents never go
  further, because most documents are not there to be turned into anything else.
  Nothing should count formal documents as outstanding work or nag about them.

  `creation_changeset/2` cannot set the status, deliberately: it is not cast, so
  a caller that supplies it is simply not heard, the same way an author cannot
  name who a block is credited to. Adoption is a person looking at a document and
  deciding it counts, and a caller able to declare its own work adopted would be
  declaring the review never needed to happen.

  Every step is one-way, and each has exactly one changeset that walks it.
  Once a document is adopted, other work starts leaning on it; letting it
  quietly become a scratch note again would pull the ground out from under that.
  Something not worth keeping gets archived instead, which is what archiving is
  for.

  Nothing here reaches `:applied` yet. Filing a task document as a work
  breakdown is what will move it, and that is not built; the value exists now so
  that the states are whole and the migration happens once.

  ## Archiving is a different question

  `archived_at` is not a status. A document in any of these states can be
  archived, and an archived `:formal` document is still one somebody vouched
  for -- it is just not in use. Folding the two together would lose that
  distinction and the time it happened.
  """

  use RintoPMO, :schema

  alias RintoPMO.Annotations.Annotation
  alias RintoPMO.Documents.BlockProposal
  alias RintoPMO.Documents.DocumentRevision
  alias RintoPMO.Projects.Project

  @type t :: %__MODULE__{}
  @type status :: :draft | :formal | :applied

  @statuses [:draft, :formal, :applied]

  schema "documents" do
    field :archived_at, :utc_datetime_usec
    field :status, Ecto.Enum, values: @statuses, default: :draft
    field :latest_revision, :any, virtual: true

    belongs_to :project, Project
    has_many :revisions, DocumentRevision
    has_many :annotations, Annotation
    has_many :proposals, BlockProposal

    timestamps()
  end

  @doc """
  The statuses a document can hold.
  """
  @spec statuses() :: [status()]
  def statuses, do: @statuses

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

  @doc false
  def formalize_changeset(%__MODULE__{status: :draft} = document),
    do: change(document, status: :formal)

  # Already adopted is not an error: the caller asked for a state the document
  # is in, and saying so twice changes nothing. This is the same answer
  # `archive_changeset/1` gives.
  def formalize_changeset(%__MODULE__{status: :formal} = document), do: change(document)

  # Already consumed is a different matter. There is no way back along this
  # axis, and quietly reporting success would tell the caller a document is
  # available to be consumed again when it is not.
  def formalize_changeset(%__MODULE__{status: :applied} = document) do
    document
    |> change()
    |> add_error(:status, "an applied document cannot go back to formal")
  end

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
