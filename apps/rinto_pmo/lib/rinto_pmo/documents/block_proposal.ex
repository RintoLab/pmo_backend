defmodule RintoPMO.Documents.BlockProposal do
  @moduledoc """
  A proposed change to a document, made by one topic.

  AI does not write a document; it proposes. The working copy between two
  revisions is not a second set of blocks but the latest revision plus the
  proposals standing against it, which is what lets several topics edit one
  document without forking it.

  ## Three scopes

  | `scope` | changes | keyed by |
  |---|---|---|
  | `:block` | one block's content | `block_id` |
  | `:document` | the whole block sequence | `document_id` |
  | `:title` | the revision's title | `document_id` |

  `:block` came first and is still the ordinary case. It has one shape of
  outcome -- an `update` op -- which is why a change that splits, merges,
  inserts or reorders blocks could not be expressed at all: `BlockOps` has the
  vocabulary, a block proposal has no way to reach it.

  `:document` carries whole-document markdown, compiled at propose time into the
  op list held in `block_ops`. The compilation preserves `block_id` wherever
  content is unchanged, so the blocks nobody touched keep their annotations and
  their history; only genuinely rewritten blocks lose the thread.

  `:title` is separate rather than folded into `:document` because a title lives
  on the revision and is never read out of the body (see
  `RintoPMO.Documents.Markdown`), so no amount of markdown can carry one.

  ## Identity is one live slot per topic

  Not one row per edit. A topic told to tighten the same paragraph five times
  is one intent iterating, so the fifth revision updates the same row rather
  than stacking a fifth proposal. That is what makes the contention test
  trivial:

      live proposals on a block == 1  ->  changed, uncontested
      live proposals on a block >= 2  ->  contended, someone must decide

  No locks, no version numbers, no first-writer-wins. Topics write their own
  slots, so nothing can overwrite anything and there is no race to detect. Two
  partial unique indexes enforce it: `(block_id, conversation_id)` for the block
  scope, `(document_id, conversation_id, scope)` for the other two. `scope` is in
  the second so one topic can hold a live title proposal and a live document
  proposal at once -- they change different things, and neither is an
  alternative to the other.

  ## Scopes are not alternatives to each other

  Two block proposals on one block compete to be that block's next content, so
  picking one is a decision. A document proposal is not competing for a block;
  it claims the whole sequence, including which blocks exist. "Which of these
  two" does not typecheck between them, and they cannot be committed together:
  the document proposal's ops already settle every block, and layering another
  block's `update` on top would either collide with a block it deleted or
  silently overrule it.

  So a document proposal is committed alone, and doing so marks every other live
  proposal on that document `superseded` -- their anchors may no longer exist.
  In the other direction nothing special is needed: committing block proposals
  moves the document on, and a document proposal is only committable while
  `base_revision_id` is still the latest revision. Whichever lands first
  invalidates the other, which is why neither a lock nor a priority is wanted.

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
  @type scope :: :block | :document | :title

  @statuses [:live, :accepted, :rejected, :superseded]
  @scopes [:block, :document, :title]

  schema "block_proposals" do
    field :scope, Ecto.Enum, values: @scopes, default: :block
    field :block_id, UUIDv7
    field :content, :string
    field :block_ops, {:array, :map}
    field :change_summary, :string
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

  @doc """
  The scopes a proposal can have.
  """
  @spec scopes() :: [scope()]
  def scopes, do: @scopes

  @doc false
  def changeset(%__MODULE__{} = proposal \\ %__MODULE__{}, attrs) do
    proposal
    |> cast(attrs, [
      :document_id,
      :scope,
      :block_id,
      :conversation_id,
      :actor_id,
      :content,
      :block_ops,
      :change_summary,
      :base_revision_id
    ])
    |> validate_required([
      :document_id,
      :scope,
      # Required on the way in even though the column is nullable: a proposal's
      # identity is (block, conversation) or (document, conversation, scope), so
      # one cannot be made without a topic. The column allows null only so that
      # losing a topic does not take the proposal with it.
      :conversation_id,
      :actor_id,
      :content,
      :base_revision_id
    ])
    |> validate_scope()
    |> validate_length(:content, min: 1)
    |> foreign_key_constraint(:document_id)
    |> foreign_key_constraint(:conversation_id)
    |> foreign_key_constraint(:actor_id)
    |> foreign_key_constraint(:base_revision_id)
    |> unique_constraint([:block_id, :conversation_id],
      name: :block_proposals_one_live_per_block_and_conversation
    )
    |> unique_constraint([:document_id, :conversation_id, :scope],
      name: :block_proposals_one_live_document_scope_per_conversation
    )
  end

  # A block proposal is identified by its block, and the two document-level
  # scopes are identified by the document -- naming a block there would be
  # claiming an anchor the proposal does not have. The database enforces the
  # same rule; this is so the caller gets a field error rather than a constraint
  # violation.
  defp validate_scope(changeset) do
    case get_field(changeset, :scope) do
      :block -> validate_required(changeset, [:block_id])
      scope when scope in [:document, :title] -> reject_block_id(changeset, scope)
      _absent -> changeset
    end
  end

  defp reject_block_id(changeset, scope) do
    if get_field(changeset, :block_id) do
      add_error(changeset, :block_id, "is not allowed for a #{scope} proposal")
    else
      changeset
    end
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
