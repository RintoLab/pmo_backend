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
  alias RintoPMO.Documents.Document
  alias RintoPMO.Documents.DocumentBlock
  alias RintoPMO.Documents.DocumentRevision
  alias RintoPMO.Projects.Project
  alias RintoPMO.Projects.ProjectRepo
  alias RintoPMO.RepoCredentials.RepoCredential

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

  def document_factory do
    %Document{project: build(:project)}
  end

  def document_revision_factory do
    %DocumentRevision{
      document: build(:document),
      title: sequence(:document_revision_title, &"Document #{&1}")
    }
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
      git_url: "https://example.com/owner/repo.git",
      branch: "main"
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
      content: sequence(:annotation_content, &"Annotation #{&1}"),
      status: :open
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

  def conversation_factory do
    %Conversation{
      title: sequence(:conversation_title, &"Topic #{&1}"),
      actor: build(:actor)
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
      block_id: UUIDv7.generate(),
      content: sequence(:block_proposal_content, &"Proposed text #{&1}"),
      status: :live
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
