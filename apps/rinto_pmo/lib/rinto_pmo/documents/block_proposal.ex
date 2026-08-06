defmodule RintoPMO.Documents.BlockProposal do
  @moduledoc """
  A proposed replacement for one block, made by one topic.

  AI does not write a document; it proposes. The working copy between two
  revisions is not a second set of blocks but the latest revision plus the
  proposals standing against it, which is what lets several topics edit one
  document without forking it.

  ## Identity is `(block, conversation)`

  Not one row per edit. A topic told to tighten the same paragraph five times
  is one intent iterating, so the fifth revision updates the same row rather
  than stacking a fifth proposal. That is what makes the contention test
  trivial:

      live proposals on a block == 1  ->  changed, uncontested
      live proposals on a block >= 2  ->  contended, someone must decide

  No locks, no version numbers, no first-writer-wins. Topics write their own
  slots, so nothing can overwrite anything and there is no race to detect. The
  database enforces the one-live-per-topic rule with a partial unique index.

  `base_revision_id` is recorded but is deliberately *not* the conflict test: a
  working copy is loaded per-document from the latest revision, so every
  topic's base is identical by construction and could never tell two proposals
  apart.

  ## Nothing is ever deleted

  Decisions move `status`, they do not remove rows. A proposal referenced by a
  topic would leave a dangling reference behind, breaking that topic's replay;
  and "why was A chosen over B" is the single most valuable thing this system
  records, which discarding the loser would halve. What is wanted is that it
  leaves the workspace view, not the database.
  """

  use RintoPMO, :schema

  alias RintoPMO.Actors.Actor
  alias RintoPMO.Conversations.Conversation
  alias RintoPMO.Documents.Document
  alias RintoPMO.Documents.DocumentRevision

  @type t :: %__MODULE__{}
  @type status :: :live | :accepted | :rejected | :superseded

  @statuses [:live, :accepted, :rejected, :superseded]

  schema "block_proposals" do
    field :block_id, UUIDv7
    field :content, :string
    field :status, Ecto.Enum, values: @statuses, default: :live
    field :decided_at, :utc_datetime_usec

    belongs_to :document, Document
    belongs_to :conversation, Conversation
    belongs_to :actor, Actor
    belongs_to :base_revision, DocumentRevision
    belongs_to :decided_by_actor, Actor

    timestamps()
  end

  @doc """
  The statuses a proposal can hold.
  """
  @spec statuses() :: [status()]
  def statuses, do: @statuses

  @doc false
  def changeset(%__MODULE__{} = proposal \\ %__MODULE__{}, attrs) do
    proposal
    |> cast(attrs, [
      :document_id,
      :block_id,
      :conversation_id,
      :actor_id,
      :content,
      :base_revision_id
    ])
    |> validate_required([
      :document_id,
      :block_id,
      # Required on the way in even though the column is nullable: a proposal's
      # identity is (block, conversation), so one cannot be made without a
      # topic. The column allows null only so that losing a topic does not take
      # the proposal with it.
      :conversation_id,
      :actor_id,
      :content,
      :base_revision_id
    ])
    |> validate_length(:content, min: 1)
    |> foreign_key_constraint(:document_id)
    |> foreign_key_constraint(:conversation_id)
    |> foreign_key_constraint(:actor_id)
    |> foreign_key_constraint(:base_revision_id)
    |> unique_constraint([:block_id, :conversation_id],
      name: :block_proposals_one_live_per_block_and_conversation
    )
  end

  @doc false
  def content_changeset(%__MODULE__{} = proposal, attrs) do
    # The same intent iterating, so the row is rewritten rather than replaced.
    # The actor travels with it: the last writer is the current author.
    proposal
    |> cast(attrs, [:actor_id, :content])
    |> validate_required([:actor_id, :content])
    |> validate_length(:content, min: 1)
    |> foreign_key_constraint(:actor_id)
  end

  @doc false
  def decision_changeset(%__MODULE__{} = proposal, status, actor_id, decided_at)
      when status in [:accepted, :rejected, :superseded] do
    proposal
    |> change()
    |> put_change(:status, status)
    |> put_change(:decided_by_actor_id, actor_id)
    |> put_change(:decided_at, decided_at)
    |> foreign_key_constraint(:decided_by_actor_id)
    |> check_constraint(:decided_by_actor_id,
      name: :block_proposals_decision_complete
    )
  end
end
