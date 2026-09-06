defmodule RintoPMO.Documents.BlockProposal do
  @moduledoc """
  One proposed local change to a document.

  AI does not write a document; it proposes. The working copy between two
  revisions is not a second set of blocks but the latest revision plus the
  proposals standing against it, which is what lets several topics edit one
  document without forking it.

  ## One row is one operation

  | `scope` | `operation` | changes | keyed by |
  |---|---|---|---|
  | `:block` | `:update` | one block's text | `block_id` |
  | `:block` | `:insert` | a new block, after `after_block_id` | its own `block_id` |
  | `:block` | `:delete` | one block's existence | `block_id` |
  | `:block` | `:move` | one block's place | `block_id` |
  | `:title` | `:update` | the revision's title | `document_id` |

  Whole-document Markdown is an *input format*, never a stored proposal. At
  propose time it is compiled into these operations and each one becomes a row,
  because each one is a separate thing to accept or refuse: a person taking the
  new section and leaving the deleted paragraph is the ordinary case, and a
  single row holding both offers them no way to say it.

  An `insert` allocates its `block_id` when it is proposed rather than when it
  commits. Reviewing, discussing and publishing then all name the same block,
  and the paragraph a person argued about is the paragraph that lands.

  `:title` is separate rather than an operation on a block because a title lives
  on the revision and is never read out of the body (see
  `RintoPMO.Documents.Markdown`), so no amount of Markdown can carry one. It is
  not otherwise special: title proposals compete with each other, are adopted
  and published like any other candidate, and none of them has to win.

  ## The payload is fixed; the state is not

  A proposal id names one modification forever. `scope`, `operation`,
  `block_id`, `after_block_id`, `content` and `base_revision_id` are written
  once and never rewritten, because a message citing this id has to keep saying
  what it said. A topic changing its mind writes a **new** row and the old one
  becomes `superseded` -- iteration is a new id, not a mutated one.

  What does move is the state around it:

    * `staged` -- the checkbox, and nothing else. It does not resolve a
      conflict, and it does not decide what a publish contains.
    * `adopted_revision_id` -- the revision that was on screen when somebody
      chose this candidate over the ones it competes with. Holding the revision
      rather than a boolean means a later read can tell whether the choice still
      refers to anything: if what was being looked at has since changed under
      the proposal, the choice has to be made again.
    * `accepted_revision_id` -- the revision that actually applied it.
    * `status`, `decided_at`, `decided_by_actor_id`, `decided_reason`.

  ## One live slot per topic, per operation

  A topic told to tighten the same paragraph five times is one intent iterating,
  so only the fifth stands. But rewriting a paragraph and moving it are two
  intents about one block that compose, so both may stand at once. The slot is
  therefore `(block_id, conversation_id, operation)`, enforced by a partial
  unique index; the title's is `(document_id, conversation_id, scope)`.

  ## Nothing is ever deleted

  Decisions move `status`, they do not remove rows. A proposal cited by a topic
  would leave a dangling reference behind, breaking that topic's replay; and
  "why was A chosen over B" is the single most valuable thing this system
  records, which discarding the loser would halve. What is wanted is that it
  leaves the pending set, not the database.

  `:rejected` is somebody saying no. `:superseded` is the proposal being
  overtaken -- by a newer version of the same intent, or by a competing change
  that published first. They are not interchangeable, and neither is undone by
  un-adopting anything.
  """

  use RintoPMO, :schema

  alias RintoPMO.Actors.Actor
  alias RintoPMO.Conversations.Conversation
  alias RintoPMO.Documents.Document
  alias RintoPMO.Documents.DocumentRevision

  @type t :: %__MODULE__{}
  @type status :: :live | :accepted | :rejected | :superseded
  @type scope :: :block | :title
  @type operation :: :update | :insert | :delete | :move

  @statuses [:live, :accepted, :rejected, :superseded]
  @scopes [:block, :title]
  @operations [:update, :insert, :delete, :move]
  @writes_content [:update, :insert]
  @carries_anchor [:insert, :move]

  schema "block_proposals" do
    field :scope, Ecto.Enum, values: @scopes, default: :block
    field :operation, Ecto.Enum, values: @operations, default: :update
    field :block_id, UUIDv7
    field :after_block_id, UUIDv7
    field :content, :string
    field :run_id, UUIDv7
    field :run_ordinal, :integer
    field :change_summary, :string
    field :staged, :boolean, default: false
    field :status, Ecto.Enum, values: @statuses, default: :live
    field :decided_at, :utc_datetime_usec
    field :decided_reason, :string

    belongs_to :document, Document
    belongs_to :conversation, Conversation
    belongs_to :actor, Actor
    belongs_to :base_revision, DocumentRevision
    belongs_to :adopted_revision, DocumentRevision
    belongs_to :accepted_revision, DocumentRevision
    belongs_to :supersedes, __MODULE__
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

  @doc """
  The operations a proposal can carry.
  """
  @spec operations() :: [operation()]
  def operations, do: @operations

  @doc """
  Why two live proposals cannot both stand, or `nil` when they can.

  Conflict is a relation between two operations, not a property of a group. Two
  rewrites of one paragraph are alternatives; a rewrite and a move of that same
  paragraph are not, and treating them as one argument would make a person throw
  away an edit to keep a reordering. Nothing here is transitive: `:delete`
  conflicts with both `:update` and `:move`, and those two still compose.

  The answer is a reason rather than a boolean because the screen asking has to
  say what the argument is about, and "these two are in conflict" is not
  something a person can act on.
  """
  @spec conflict_reason(t(), t()) :: atom() | nil
  def conflict_reason(%__MODULE__{id: id}, %__MODULE__{id: id}), do: nil

  def conflict_reason(%__MODULE__{scope: :title}, %__MODULE__{scope: :title}),
    do: :competing_title

  def conflict_reason(%__MODULE__{scope: :block} = left, %__MODULE__{scope: :block} = right) do
    cond do
      left.operation == :insert or right.operation == :insert -> insertions(left, right)
      left.block_id != right.block_id -> nil
      true -> over_one_block(left.operation, right.operation, left, right)
    end
  end

  def conflict_reason(%__MODULE__{}, %__MODULE__{}), do: nil

  @doc """
  Whether two live proposals claim the same thing and so cannot both stand.
  """
  @spec conflicting?(t(), t()) :: boolean()
  def conflicting?(left, right), do: conflict_reason(left, right) != nil

  # An insertion claims a gap, never an existing block, so it argues only with
  # another insertion -- and then only about which of them goes first.
  defp insertions(%__MODULE__{operation: :insert} = left, %__MODULE__{operation: :insert} = right) do
    if competing_inserts?(left, right), do: :competing_insertion
  end

  defp insertions(_left, _right), do: nil

  defp over_one_block(left, right, _left_proposal, _right_proposal)
       when :delete in [left, right],
       do: :competing_deletion

  defp over_one_block(:update, :update, _left, _right), do: :competing_text

  defp over_one_block(:move, :move, left, right) do
    if left.after_block_id != right.after_block_id, do: :competing_position
  end

  # An update and a move of one block: one settles its text, the other its
  # place. Both can be taken, in either order, and neither overrules the other.
  defp over_one_block(_left, _right, _left_proposal, _right_proposal), do: nil

  # Two insertions into one gap. Where they came from the same propose call the
  # order between them is known -- it was written down -- so they are members of
  # one sequence rather than alternatives. From different calls nothing says
  # which goes first, and inventing an order is exactly the decision this system
  # leaves to a person.
  defp competing_inserts?(left, right) do
    left.after_block_id == right.after_block_id and
      (is_nil(left.run_id) or left.run_id != right.run_id)
  end

  @doc """
  The fixed payload: what makes two proposals the same modification.

  Compared rather than diffed, so that re-proposing an unchanged intent reuses
  the row it already has and every message citing it keeps pointing at the same
  thing.
  """
  @spec payload(t()) :: map()
  def payload(%__MODULE__{} = proposal) do
    %{
      scope: proposal.scope,
      operation: proposal.operation,
      block_id: proposal.block_id,
      after_block_id: proposal.after_block_id,
      content: proposal.content,
      base_revision_id: proposal.base_revision_id
    }
  end

  @doc false
  def changeset(%__MODULE__{} = proposal \\ %__MODULE__{}, attrs) do
    proposal
    |> cast(attrs, [
      :document_id,
      :scope,
      :operation,
      :block_id,
      :after_block_id,
      :conversation_id,
      :actor_id,
      :content,
      :run_id,
      :run_ordinal,
      :change_summary,
      :base_revision_id,
      :supersedes_id
    ])
    |> validate_required([
      :document_id,
      :scope,
      :operation,
      # Required on the way in even though the column is nullable: a proposal's
      # identity is (block, operation, conversation) or (document, conversation,
      # scope), so one cannot be made without a topic. The column allows null
      # only so that losing a topic does not take the proposal with it.
      :conversation_id,
      :actor_id,
      :base_revision_id
    ])
    |> validate_shape()
    |> foreign_key_constraint(:document_id)
    |> foreign_key_constraint(:conversation_id)
    |> foreign_key_constraint(:actor_id)
    |> foreign_key_constraint(:base_revision_id)
    |> foreign_key_constraint(:supersedes_id)
    |> unique_constraint([:block_id, :conversation_id, :operation],
      name: :block_proposals_one_live_per_block_operation_and_conversation
    )
    |> unique_constraint([:document_id, :conversation_id, :scope],
      name: :block_proposals_one_live_document_scope_per_conversation
    )
  end

  # Each operation names exactly what it needs and nothing it does not. The
  # database enforces the same rules; these exist so a caller gets a field error
  # rather than a constraint violation.
  defp validate_shape(changeset) do
    scope = get_field(changeset, :scope)
    operation = get_field(changeset, :operation)

    changeset
    |> validate_target(scope, operation)
    |> validate_content(operation)
    |> validate_anchor(operation)
  end

  defp validate_target(changeset, :block, _operation),
    do: validate_required(changeset, [:block_id])

  defp validate_target(changeset, :title, operation) do
    changeset =
      if operation in [:insert, :delete, :move] do
        add_error(changeset, :operation, "is not allowed for a title proposal")
      else
        changeset
      end

    if get_field(changeset, :block_id) do
      add_error(changeset, :block_id, "is not allowed for a title proposal")
    else
      changeset
    end
  end

  defp validate_target(changeset, _absent, _operation), do: changeset

  defp validate_content(changeset, operation) when operation in @writes_content do
    changeset
    |> validate_required([:content])
    |> validate_length(:content, min: 1)
  end

  defp validate_content(changeset, operation) when operation in [:delete, :move] do
    if get_field(changeset, :content) do
      add_error(changeset, :content, "is not allowed for a #{operation} proposal")
    else
      changeset
    end
  end

  defp validate_content(changeset, _absent), do: changeset

  defp validate_anchor(changeset, operation) when operation in @carries_anchor do
    # `nil` is a real anchor for an insertion at the head of the document, and
    # for a move to the front. There is nothing before the first block to name.
    changeset
  end

  defp validate_anchor(changeset, _operation) do
    if get_field(changeset, :after_block_id) do
      add_error(changeset, :after_block_id, "is only allowed for an insert or move proposal")
    else
      changeset
    end
  end

  @doc """
  Sets the checkbox, and only the checkbox.

  Not a toggle: the caller says `true` or `false` and that is what is stored, so
  two saves of the same value are one state rather than two flips.
  """
  @spec staged_changeset(t(), boolean()) :: Ecto.Changeset.t()
  def staged_changeset(%__MODULE__{} = proposal, staged) when is_boolean(staged) do
    proposal
    |> change()
    |> put_change(:staged, staged)
  end

  @doc """
  Records -- or clears -- which revision was on screen when this candidate was
  chosen.
  """
  @spec adoption_changeset(t(), UUIDv7.t() | nil) :: Ecto.Changeset.t()
  def adoption_changeset(%__MODULE__{} = proposal, revision_id) do
    proposal
    |> change()
    |> put_change(:adopted_revision_id, revision_id)
    |> foreign_key_constraint(:adopted_revision_id)
  end

  @doc false
  def decision_changeset(%__MODULE__{} = proposal, status, actor_id, decided_at, options \\ [])
      when status in [:accepted, :rejected, :superseded] do
    proposal
    |> change()
    |> put_change(:status, status)
    |> put_change(:decided_by_actor_id, actor_id)
    |> put_change(:decided_at, decided_at)
    |> put_change(:decided_reason, Keyword.get(options, :reason))
    |> put_change(:accepted_revision_id, Keyword.get(options, :accepted_revision_id))
    # A decided proposal is out of the pending set, so the checkbox and the
    # choice that only meant anything while it was pending go with it. Cleared
    # in the same change rather than in a second statement: a late `staged=true`
    # arriving after this cannot re-tick something that is no longer waiting.
    |> put_change(:staged, false)
    |> put_change(:adopted_revision_id, nil)
    |> foreign_key_constraint(:decided_by_actor_id)
    |> foreign_key_constraint(:accepted_revision_id)
    |> check_constraint(:decided_by_actor_id,
      name: :block_proposals_decision_complete
    )
  end
end
