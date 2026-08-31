defmodule RintoPMO.Factory do
  @moduledoc false

  use ExMachina.Ecto, repo: RintoPMO.Repo

  alias RintoPMO.Actors.Actor
  alias RintoPMO.Annotations.Annotation
  alias RintoPMO.Annotations.AnnotationReply
  alias RintoPMO.Attachments.Attachment
  alias RintoPMO.Conversations.Conversation
  alias RintoPMO.Conversations.Message
  alias RintoPMO.Conversations.MessageRef
  alias RintoPMO.Documents.BlockProposal
  alias RintoPMO.Documents.Decomposition
  alias RintoPMO.Documents.Document
  alias RintoPMO.Documents.DocumentBlock
  alias RintoPMO.Documents.DocumentRevision
  alias RintoPMO.Projects.Project
  alias RintoPMO.Projects.ProjectRepo
  alias RintoPMO.RepoCredentials.RepoCredential
  alias RintoPMO.Tasks.Task

  def actor_factory do
    %Actor{
      kind: :human,
      name: sequence(:actor_name, &"Actor #{&1}")
    }
  end

  def project_factory do
    %Project{
      name: sequence(:project_name, &"Project #{&1}"),
      slug: sequence(:project_slug, &"project-#{&1}"),
      description: "A project"
    }
  end

  # The project a document with none of its own is filed in. Its slug is the
  # reserved one, so there can only ever be one of these per test.
  def default_project_factory do
    %Project{
      name: "Personal",
      slug: RintoPMO.Projects.default_slug(),
      description: "Notes and documents that belong to no particular project."
    }
  end

  def document_factory do
    %Document{project: build(:project)}
  end

  def document_decomposition_factory do
    %Decomposition{source_document: build(:document)}
  end

  def document_revision_factory do
    %DocumentRevision{
      document: build(:document),
      title: sequence(:document_revision_title, &"Document #{&1}")
    }
  end

  @doc """
  Inserts the revision that supersedes `parent`, demoting it on the way.

  A document has exactly one current revision, and
  `document_revisions_one_latest_per_document` enforces it, so a history built
  by hand has to be built the way `RintoPMO.Documents.insert_revision/4` builds
  one: the parent stops being the latest before its successor exists. Inserting
  a second revision with `insert(:document_revision, document: document)`
  raises, which is the constraint working rather than a test to route around.
  """
  def insert_revision_after(%DocumentRevision{} = parent, attrs \\ []) do
    parent
    |> Ecto.Changeset.change(is_latest: false)
    |> RintoPMO.Repo.update!()

    insert(:document_revision, Keyword.put_new(attrs, :parent_id, parent.id))
  end

  def document_block_factory do
    %DocumentBlock{
      block_id: UUIDv7.generate(),
      revision: build(:document_revision),
      actor: build(:actor),
      content: "## Section\n\nContent",
      position: 0
    }
  end

  def project_repo_factory do
    %ProjectRepo{
      project: build(:project),
      name: sequence(:project_repo_name, &"repo-#{&1}"),
      git_url: "https://example.com/owner/repo.git"
    }
  end

  def repo_credential_factory do
    %RepoCredential{
      name: sequence(:repo_credential_name, &"Credential #{&1}"),
      username: sequence(:repo_credential_username, &"git-user-#{&1}"),
      token: "test-token"
    }
  end

  def annotation_factory do
    %Annotation{
      document: build(:document),
      actor: build(:actor),
      content: sequence(:annotation_content, &"Annotation #{&1}")
    }
  end

  def attachment_factory do
    %Attachment{
      actor: build(:actor),
      filename: sequence(:attachment_filename, &"image-#{&1}.png"),
      mime_type: "image/png",
      byte_size: 70,
      width: 1,
      height: 1,
      checksum: String.duplicate("0", 64)
    }
  end

  def annotation_reply_factory do
    %AnnotationReply{
      annotation: build(:annotation),
      actor: build(:actor),
      content: sequence(:annotation_reply_content, &"Reply #{&1}"),
      position: 0
    }
  end

  # Actor mode by default, matching existing rows and formal-work topics. Such
  # a topic cannot be opened without its assistant and proposals are credited
  # to that actor. Plain-chat tests opt into `mode: :chat` and clear the
  # association explicitly.
  def conversation_factory do
    %Conversation{
      title: sequence(:conversation_title, &"Topic #{&1}"),
      actor: build(:actor),
      assistant_actor: build(:actor, kind: :ai)
    }
  end

  def message_factory do
    %Message{
      conversation: build(:conversation),
      actor: build(:actor),
      role: :user,
      content: sequence(:message_content, &"Message #{&1}"),
      position: 0
    }
  end

  def block_proposal_factory do
    revision = build(:document_revision)

    %BlockProposal{
      document: revision.document,
      base_revision: revision,
      conversation: build(:conversation),
      actor: build(:actor),
      scope: :block,
      block_id: UUIDv7.generate(),
      content: sequence(:block_proposal_content, &"Proposed text #{&1}"),
      status: :live
    }
  end

  def task_factory do
    %Task{
      project: build(:project),
      kind: :work,
      title: sequence(:task_title, &"Task #{&1}"),
      status: :open
    }
  end

  def summary_task_factory do
    %Task{
      project: build(:project),
      kind: :summary,
      title: sequence(:task_title, &"Chunk #{&1}"),
      status: :open
    }
  end

  def message_ref_factory do
    %MessageRef{
      message: build(:message),
      ref_type: "document",
      position: 0,
      ref_id: UUIDv7.generate(),
      payload: %{"type" => "document", "id" => UUIDv7.generate()}
    }
  end
end
