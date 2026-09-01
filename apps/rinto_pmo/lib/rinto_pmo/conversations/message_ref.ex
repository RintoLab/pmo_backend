defmodule RintoPMO.Conversations.MessageRef do
  @moduledoc """
  One thing in this system that a message put in front of the model.

  Every ref is stored twice over, on purpose:

    * `payload` is the ref map exactly as the client sent it, and is what
      replay hands back to `RintoPMO.Agent.PromptBuilder`
    * `ref_type` / `ref_id` are the normalised, indexed form, and are what
      answers "which topics discussed this annotation?"

  Neither can be derived from the other. A project ref is keyed by `slug`
  rather than `id` (see `PromptBuilder`'s reference table), so normalising it
  loses the shape replay needs, while keeping only the payload leaves nothing
  to index. `ref_id` for a project is the id its slug resolved to at write
  time.

  `ref_document_id` is set for a ref that lives *inside* a document --
  an annotation, a block proposal, and whatever document-internal resource
  comes after them -- and names the document it lives in. Such a thing is only
  ever reachable through its document, which is the rule
  `PromptBuilder.resolve/1` enforces; it is also what lets
  `RintoPMO.Conversations.list_conversations/1` answer "which topics touched
  this document?" without a join table. A `document` ref does not use it -- for
  that one, `ref_id` *is* the document -- and a `project` or `attachment` ref
  has no document to name.

  `position` preserves the order the client gave, because `PromptBuilder`
  expands refs in that order and a replay has to reproduce it. Insertion order
  cannot stand in: UUIDv7 orders only to the millisecond, and a message's refs
  are all written inside one.

  It carries a second job, which is why it is the client's index and not merely
  *an* ordering: a mention in the message body points at its ref by that index
  (`[document](reference#0)`), and `PromptBuilder` rewrites those pointers when
  the turn is replayed. `position` is the lookup key that makes the rewrite
  reproducible weeks later, so it has to stay the number the client sent.

  **Refs are therefore deliberately not deduplicated on the way in.** A mention
  UI has no way to reuse an entry already in the array, so citing one document
  twice sends it twice; collapsing those rows would renumber the positions and
  strand the pointer that named the later one. Deduplication happens where it
  belongs -- once, in `PromptBuilder`, deciding what gets expanded.

  `position` is otherwise unconstrained -- not unique per message, not checked
  non-negative. A message's refs are written once, in a single transaction,
  numbered from their index in the list, and a message is never edited, so
  nothing appends a ref later. There is no interleaving to guard against
  (unlike `Message` or `RintoPMO.Annotations.AnnotationReply`, whose positions
  are contended).
  """

  use RintoPMO, :schema

  alias RintoPMO.Conversations.Message

  @type t :: %__MODULE__{}

  schema "message_refs" do
    # Not an Ecto.Enum and not constrained in the database: the set of ref
    # types grows with PromptBuilder, and an unknown type should be stored and
    # ignored rather than reject the message that carried it.
    field :ref_type, :string
    field :position, :integer
    field :ref_id, UUIDv7
    field :ref_document_id, UUIDv7
    field :payload, :map

    belongs_to :message, Message

    timestamps()
  end

  @doc false
  def changeset(%__MODULE__{} = message_ref \\ %__MODULE__{}, attrs) do
    message_ref
    |> cast(attrs, [:message_id, :ref_type, :position, :ref_id, :ref_document_id, :payload])
    |> validate_required([:ref_type, :position, :payload])
    |> foreign_key_constraint(:message_id)
  end
end
