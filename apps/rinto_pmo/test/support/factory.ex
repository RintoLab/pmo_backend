defmodule RintoPMO.Factory do
  @moduledoc false

  use ExMachina.Ecto, repo: RintoPMO.Repo

  alias RintoPMO.Actors.Actor
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
end
