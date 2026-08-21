defmodule RintoPMO.Documents.Decomposition do
  @moduledoc """
  One attempt to break a document down into a task document.

  Not the product -- that is an ordinary document, see
  `RintoPMO.Documents.decompose_document/1`. This is the attempt, and it exists
  because a person is watching it happen: it is what a second click is refused
  against, what the spinner reads, and where a failure is written down.

  ## The statuses are a job's, not a document's

  `pending` and `running` are *in flight*; `succeeded` and `failed` are over.
  Nothing moves out of a finished state -- asking again makes a new row, which
  is what "try again" means when the first answer is already recorded.

  `error` is filled only by `failed`, and holds whatever the model call said as
  it said it. There is nothing to classify it into: the reasons a provider
  refuses are its own, and a tidier vocabulary here would mean guessing which
  bucket the sentence belongs in.
  """

  use RintoPMO, :schema

  alias RintoPMO.Documents.Document

  @type t :: %__MODULE__{}
  @type status :: :pending | :running | :succeeded | :failed

  @statuses [:pending, :running, :succeeded, :failed]
  @in_flight [:pending, :running]

  schema "document_decompositions" do
    field :status, Ecto.Enum, values: @statuses, default: :pending
    field :error, :string

    belongs_to :source_document, Document
    belongs_to :result_document, Document

    timestamps()
  end

  @doc """
  The statuses an attempt can hold.
  """
  @spec statuses() :: [status()]
  def statuses, do: @statuses

  @doc """
  The statuses that mean an attempt has not finished.
  """
  @spec in_flight_statuses() :: [status()]
  def in_flight_statuses, do: @in_flight

  @doc false
  def creation_changeset(%__MODULE__{} = decomposition \\ %__MODULE__{}, source_document_id) do
    decomposition
    |> change(source_document_id: source_document_id)
    |> foreign_key_constraint(:source_document_id)
    |> unique_constraint(:source_document_id,
      name: :document_decompositions_one_in_flight_per_source,
      message: "already has a decomposition in flight"
    )
  end

  @doc false
  def running_changeset(%__MODULE__{} = decomposition),
    do: change(decomposition, status: :running)

  @doc false
  def succeeded_changeset(%__MODULE__{} = decomposition, %Document{} = result) do
    decomposition
    |> change(status: :succeeded, result_document_id: result.id, error: nil)
    |> foreign_key_constraint(:result_document_id)
  end

  @doc false
  def failed_changeset(%__MODULE__{} = decomposition, reason) when is_binary(reason) do
    change(decomposition, status: :failed, error: reason, result_document_id: nil)
  end
end
