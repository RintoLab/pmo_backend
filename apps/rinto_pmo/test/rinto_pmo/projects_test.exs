defmodule RintoPMO.ProjectsTest do
  use RintoPMO.DataCase, async: true

  alias RintoPMO.Projects
  alias RintoPMO.Projects.Project
  alias RintoPMO.Projects.ProjectRepo

  describe "projects" do
    test "creates a project and fetches details with multiple repositories" do
      assert {:ok, %Project{} = project} =
               Projects.create_project(%{
                 name: "Rinto PMO",
                 slug: "rinto-pmo",
                 description: "Project management"
               })

      first_repo = insert(:project_repo, project: project, name: "backend")
      second_repo = insert(:project_repo, project: project, name: "frontend")

      fetched = Projects.get_project_by_slug!(project.slug)

      assert fetched.id == project.id
      assert Enum.map(fetched.repos, & &1.id) == [first_repo.id, second_repo.id]
    end

    test "lists and fetches only active projects through the active lookup" do
      active = insert(:project, name: "Active")
      archived = insert(:project, name: "Archived", status: :archived)

      assert Enum.map(Projects.list_projects(), & &1.id) == [active.id]
      assert Projects.get_active_project_by_slug!(active.slug).id == active.id
      assert Projects.get_project_by_slug!(archived.slug).id == archived.id

      assert_raise Ecto.NoResultsError, fn ->
        Projects.get_active_project_by_slug!(archived.slug)
      end
    end

    test "enforces unique project slugs" do
      insert(:project, slug: "same-slug")

      assert {:error, changeset} =
               Projects.create_project(%{
                 name: "Duplicate",
                 slug: "same-slug",
                 description: "Duplicate"
               })

      assert "has already been taken" in errors_on(changeset).slug
    end

    test "ordinary updates cannot change status" do
      project = insert(:project, status: :active)

      assert {:ok, updated} =
               Projects.update_project(project, %{name: "Updated", status: :archived})

      assert updated.name == "Updated"
      assert updated.status == :active
    end

    test "archives a project idempotently without deleting it" do
      project = insert(:project)

      assert {:ok, archived} = Projects.archive_project(project)
      assert archived.status == :archived
      assert {:ok, archived_again} = Projects.archive_project(archived)
      assert archived_again.status == :archived
      assert Projects.get_project_by_slug!(project.slug).id == project.id
      assert Projects.list_projects() == []
    end
  end

  describe "project repositories" do
    test "creates and lists multiple repositories in one active project" do
      project = insert(:project)

      assert {:ok, %ProjectRepo{} = backend} =
               Projects.create_project_repo(project, repo_attrs("backend"))

      assert {:ok, %ProjectRepo{} = frontend} =
               Projects.create_project_repo(project, repo_attrs("frontend"))

      assert Enum.map(Projects.list_project_repos(project), & &1.id) == [
               backend.id,
               frontend.id
             ]
    end

    test "enforces repository name uniqueness within a project" do
      first_project = insert(:project)
      second_project = insert(:project)

      assert {:ok, _repo} =
               Projects.create_project_repo(first_project, repo_attrs("backend"))

      assert {:error, changeset} =
               Projects.create_project_repo(first_project, repo_attrs("backend"))

      assert "has already been taken" in errors_on(changeset).name

      assert {:ok, _repo} =
               Projects.create_project_repo(second_project, repo_attrs("backend"))
    end

    test "scopes repository ids to the requested parent project" do
      project = insert(:project)
      other_project = insert(:project)
      project_repo = insert(:project_repo, project: project)

      assert Projects.get_project_repo!(project, project_repo.id).id == project_repo.id

      assert_raise Ecto.NoResultsError, fn ->
        Projects.get_project_repo!(other_project, project_repo.id)
      end
    end

    test "reuses one credential across repositories" do
      project = insert(:project)
      credential = insert(:repo_credential)

      assert {:ok, first_repo} =
               Projects.create_project_repo(
                 project,
                 repo_attrs("backend", credential.id)
               )

      assert {:ok, second_repo} =
               Projects.create_project_repo(
                 project,
                 repo_attrs("frontend", credential.id)
               )

      assert first_repo.credential_id == credential.id
      assert second_repo.credential_id == credential.id
    end

    test "rejects a credential id that does not exist" do
      project = insert(:project)

      assert {:error, changeset} =
               Projects.create_project_repo(
                 project,
                 repo_attrs("backend", UUIDv7.generate())
               )

      assert "does not exist" in errors_on(changeset).credential_id
    end

    test "does not accept synchronization results through repository configuration" do
      project = insert(:project)

      assert {:ok, project_repo} =
               Projects.create_project_repo(
                 project,
                 Map.put(repo_attrs("backend"), :last_sync_error, "forged")
               )

      assert project_repo.last_sync_error == nil
    end

    test "updates and hard deletes a scoped repository" do
      project = insert(:project)
      project_repo = insert(:project_repo, project: project)
      scoped_repo = Projects.get_project_repo!(project, project_repo.id)

      assert {:ok, updated} = Projects.update_project_repo(scoped_repo, %{branch: "next"})
      assert updated.branch == "next"

      assert {:ok, deleted} = Projects.delete_project_repo(updated)
      assert deleted.id == project_repo.id
      assert Repo.get(ProjectRepo, project_repo.id) == nil
    end
  end

  defp repo_attrs(name, credential_id \\ nil) do
    %{
      name: name,
      git_url: "https://example.com/owner/#{name}.git",
      branch: "main",
      credential_id: credential_id
    }
  end
end
