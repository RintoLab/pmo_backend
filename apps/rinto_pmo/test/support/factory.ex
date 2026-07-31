defmodule RintoPMO.Factory do
  @moduledoc false

  use ExMachina.Ecto, repo: RintoPMO.Repo

  alias RintoPMO.Actors.Actor
  alias RintoPMO.Annotations.Annotation
  alias RintoPMO.Annotations.AnnotationReply
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
      content: sequence(:annotation_content, &"Annotation #{&1}")
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
end
