defmodule RintoPMO.Documents.Behaviour do
  @moduledoc false

  alias RintoPMO.Documents.BlockProposal
  alias RintoPMO.Documents.Document
  alias RintoPMO.Documents.DocumentRevision

  @type filter :: %{
          optional(:project) => :unassigned | UUIDv7.t(),
          optional(:status) => Document.status()
        }

  @type proposal_filter :: %{
          optional(:id) => UUIDv7.t(),
          optional(:status) => BlockProposal.status(),
          optional(:block_id) => UUIDv7.t(),
          optional(:conversation_id) => UUIDv7.t()
        }

  @typedoc """
  The rows written by one proposal request, what they add up to, any prior rows
  they replaced, and every argument the request walked into.
  """
  @type proposed :: %{
          proposals: [BlockProposal.t()],
          summary: %{
            changed: non_neg_integer(),
            added: non_neg_integer(),
            removed: non_neg_integer(),
            moved: non_neg_integer()
          },
          superseded: [UUIDv7.t()],
          contended: [%{proposal_id: UUIDv7.t(), conflicting_proposal_ids: [UUIDv7.t()]}]
        }

  @typedoc """
  One pair of live proposals that cannot both stand, and what they are arguing
  about. A pair rather than a group: conflict is a relation, and nothing about
  it is transitive.
  """
  @type contention :: %{
          reason: atom(),
          proposal_ids: [UUIDv7.t()],
          scope: BlockProposal.scope(),
          block_id: UUIDv7.t() | nil
        }

  @typedoc """
  One proposal as a review screen needs it: the row, what it still means against
  the document as it now stands, whether the choice that picked it still holds,
  and what it is competing with.
  """
  @type proposal_detail :: %{
          proposal: BlockProposal.t(),
          state: :applicable | :already_applied | :needs_confirmation | :not_applicable,
          reason: atom() | nil,
          adopted: boolean(),
          adoption_stale: boolean(),
          conflicting_proposal_ids: [UUIDv7.t()],
          current_revision_id: UUIDv7.t()
        }

  @typedoc """
  A consistent read of a document's proposals: the comparison and the revision
  it was computed against, from one snapshot.
  """
  @type proposal_review :: %{
          current_revision_id: UUIDv7.t(),
          proposals: [proposal_detail()]
        }

  @typedoc """
  What one publish did. `revision` is `nil` when every selected proposal had
  already been applied, which writes nothing and says so.
  """
  @type publication :: %{
          result: :published | :already_applied,
          revision: DocumentRevision.t() | nil,
          current_revision_id: UUIDv7.t(),
          document_id: UUIDv7.t(),
          accepted: [UUIDv7.t()],
          superseded: [UUIDv7.t()],
          already_applied: [UUIDv7.t()]
        }

  @typedoc """
  One of a topic's proposals, and whether anybody else is proposing into the
  same slot.
  """
  @type standing_proposal :: %{proposal: proposal_detail(), contended: boolean()}

  @typedoc """
  What one topic has standing against one document. The document carries its
  latest revision, so a review screen has a title without a second read.
  """
  @type working_set_entry :: %{document: Document.t(), proposals: [standing_proposal()]}

  @typedoc """
  One block as a single topic sees it: its own proposal standing in where it
  has one, and only the count of anybody else's.
  """
  @type conversation_block :: %{
          block_id: UUIDv7.t(),
          position: non_neg_integer(),
          content: String.t(),
          proposal_id: UUIDv7.t() | nil,
          proposed?: boolean(),
          other_proposals: non_neg_integer()
        }

  @type conversation_document_view :: %{
          revision_id: UUIDv7.t(),
          blocks: [conversation_block()],
          title: String.t() | nil,
          unapplicable: [map()]
        }

  @callback list_documents(filter()) :: [Document.t()]
  @callback get_document!(UUIDv7.t()) :: Document.t()
  @callback create_document(map()) ::
              {:ok, Document.t()} | {:error, Ecto.Changeset.t()}
  @callback preview_blocks(String.t()) :: {:ok, [String.t()]} | {:error, term()}
  @callback refile_document(Document.t(), UUIDv7.t()) ::
              {:ok, Document.t()} | {:error, Ecto.Changeset.t()}
  @callback archive_document(Document.t()) ::
              {:ok, Document.t()} | {:error, Ecto.Changeset.t()}
  @callback formalize_document(Document.t()) ::
              {:ok, Document.t()} | {:error, Ecto.Changeset.t()}
  @callback pin_document(Document.t()) ::
              {:ok, Document.t()} | {:error, Ecto.Changeset.t()}
  @callback unpin_document(Document.t()) ::
              {:ok, Document.t()} | {:error, Ecto.Changeset.t()}

  @callback list_revisions(Document.t()) :: [DocumentRevision.t()]
  @callback get_revision!(Document.t(), UUIDv7.t()) :: DocumentRevision.t()
  @callback create_revision(Document.t(), map()) ::
              {:ok, DocumentRevision.t()}
              | {:error, Ecto.Changeset.t()}
              | {:error, atom(), map()}

  @callback list_proposals(Document.t(), proposal_filter()) :: [BlockProposal.t()]
  @callback review_proposals(Document.t(), proposal_filter()) ::
              {:ok, proposal_review()} | {:error, atom(), map()}
  @callback get_proposal!(Document.t(), UUIDv7.t()) :: BlockProposal.t()
  @callback live_conversation_proposals(UUIDv7.t()) :: [BlockProposal.t()]
  @callback conversation_working_set(UUIDv7.t()) :: [working_set_entry()]
  @callback propose_block(Document.t(), map()) ::
              {:ok, proposed()}
              | {:error, Ecto.Changeset.t()}
              | {:error, atom(), map()}
  @callback propose_title(Document.t(), map()) ::
              {:ok, proposed()}
              | {:error, Ecto.Changeset.t()}
              | {:error, atom(), map()}
  @callback propose_document(Document.t(), map()) ::
              {:ok, proposed()}
              | {:error, Ecto.Changeset.t()}
              | {:error, atom(), map()}
  @callback stage_proposal(Document.t(), UUIDv7.t(), boolean()) ::
              {:ok, proposal_detail()}
              | {:error, Ecto.Changeset.t()}
              | {:error, atom(), map()}
  @callback adopt_proposal(Document.t(), UUIDv7.t(), UUIDv7.t(), UUIDv7.t()) ::
              {:ok, proposal_detail()}
              | {:error, Ecto.Changeset.t()}
              | {:error, atom(), map()}
  @callback unadopt_proposal(Document.t(), UUIDv7.t()) ::
              {:ok, proposal_detail()}
              | {:error, Ecto.Changeset.t()}
              | {:error, atom(), map()}
  @callback reject_proposal(Document.t(), UUIDv7.t(), UUIDv7.t(), String.t() | nil) ::
              {:ok, proposal_detail()}
              | {:error, Ecto.Changeset.t()}
              | {:error, atom(), map()}
  @callback contentions(Document.t()) :: [contention()]
  @callback blocks_for_conversation(Document.t(), UUIDv7.t()) :: [conversation_block()]
  @callback conversation_document_view(Document.t(), UUIDv7.t()) ::
              {:ok, conversation_document_view()}
  @callback commit_proposals(Document.t(), map()) ::
              {:ok, publication()}
              | {:error, Ecto.Changeset.t()}
              | {:error, atom(), map()}
  @callback commit_many([{Document.t(), map()}]) ::
              {:ok, [publication()]}
              | {:error, Ecto.Changeset.t()}
              | {:error, atom(), map()}
  @callback apply_document(Document.t()) ::
              {:ok, Document.t()} | {:error, Ecto.Changeset.t()}
end
