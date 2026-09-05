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
          optional(:status) => BlockProposal.status(),
          optional(:block_id) => UUIDv7.t(),
          optional(:conversation_id) => UUIDv7.t()
        }

  @typedoc """
  The rows written by one proposal request, its operation summary, any prior
  rows replaced by it, and every contention the request encountered.

  `proposal` and `live_proposals` remain available to internal callers during
  the response transition; the REST representation exposes the four plural
  fields only.
  """
  @type proposed :: %{
          proposal: BlockProposal.t(),
          live_proposals: pos_integer(),
          proposals: [BlockProposal.t()],
          summary: %{
            changed: non_neg_integer(),
            added: non_neg_integer(),
            removed: non_neg_integer()
          },
          superseded: [UUIDv7.t()],
          contended: [map()]
        }

  @type contention :: %{block_id: UUIDv7.t(), proposals: [BlockProposal.t()]}

  @typedoc """
  One of a topic's proposals, and whether anybody else is proposing into the
  same slot.
  """
  @type standing_proposal :: %{proposal: BlockProposal.t(), contended: boolean()}

  @typedoc """
  What one topic has standing against one document. The document carries its
  latest revision, so a review screen has a title without a second read.
  """
  @type working_set_entry :: %{document: Document.t(), proposals: [standing_proposal()]}

  @typedoc """
  One document-level argument: a scope, and the proposals competing in it.
  """
  @type scope_contention :: %{
          optional(:overlaps_block_ids) => [UUIDv7.t()],
          scope: BlockProposal.scope(),
          proposals: [BlockProposal.t()]
        }

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
          document_proposal: BlockProposal.t() | nil
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

  @callback list_revisions(Document.t()) :: [DocumentRevision.t()]
  @callback get_revision!(Document.t(), UUIDv7.t()) :: DocumentRevision.t()
  @callback create_revision(Document.t(), map()) ::
              {:ok, DocumentRevision.t()}
              | {:error, Ecto.Changeset.t()}
              | {:error, atom(), map()}

  @callback list_proposals(Document.t(), proposal_filter()) :: [BlockProposal.t()]
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
  @callback rebase_document_proposal(Document.t(), UUIDv7.t()) ::
              {:ok, BlockProposal.t()}
              | {:error, Ecto.Changeset.t()}
              | {:error, atom(), map()}
  @callback contentions(Document.t()) :: [contention()]
  @callback scope_contentions(Document.t()) :: [scope_contention()]
  @callback document_proposal_for_conversation(Document.t(), UUIDv7.t()) ::
              BlockProposal.t() | nil
  @callback blocks_for_conversation(Document.t(), UUIDv7.t()) :: [conversation_block()]
  @callback conversation_document_view(Document.t(), UUIDv7.t()) ::
              {:ok, conversation_document_view()}
  @callback decide_block(Document.t(), UUIDv7.t(), UUIDv7.t(), UUIDv7.t()) ::
              {:ok, BlockProposal.t()}
              | {:error, Ecto.Changeset.t()}
              | {:error, atom(), map()}
  @callback decide_title(Document.t(), UUIDv7.t(), UUIDv7.t()) ::
              {:ok, BlockProposal.t()}
              | {:error, Ecto.Changeset.t()}
              | {:error, atom(), map()}
  @callback decide_document(Document.t(), UUIDv7.t(), UUIDv7.t()) ::
              {:ok, BlockProposal.t()}
              | {:error, Ecto.Changeset.t()}
              | {:error, atom(), map()}
  @callback commit_proposals(Document.t(), map()) ::
              {:ok, DocumentRevision.t()}
              | {:error, Ecto.Changeset.t()}
              | {:error, atom(), map()}
  @callback commit_many([{Document.t(), map()}]) ::
              {:ok, [DocumentRevision.t()]}
              | {:error, Ecto.Changeset.t()}
              | {:error, atom(), map()}
  @callback apply_document(Document.t()) ::
              {:ok, Document.t()} | {:error, Ecto.Changeset.t()}
end
