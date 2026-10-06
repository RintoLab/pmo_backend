defmodule RintoPMO.TaskReposTest do
  use RintoPMO.DataCase, async: true

  alias RintoPMO.Documents
  alias RintoPMO.DocumentsMock
  alias RintoPMO.Projects
  alias RintoPMO.Tasks

  test "creation requires exactly one repository from the requirement's project" do
    project = insert(:project)
    requirement = insert(:requirement, project: project)
    repository = insert(:project_repo, project: project)
    attrs = %{title: "Work", requirement_id: requirement.id}

    assert {:error, chset} = Tasks.create_task(project, attrs)
    assert errors_on(chset).repo_id == ["can't be blank"]

    for id <- [nil, UUIDv7.generate(), insert(:project_repo).id, [repository.id]] do
      assert {:error, chset} = Tasks.create_task(project, Map.put(attrs, :repo_id, id))
      assert errors_on(chset).repo_id
    end

    assert {:ok, task} = Tasks.create_task(project, Map.put(attrs, :repo_id, repository.id))
    assert task.repo_id == repository.id
    assert Tasks.get_task!(task.id).repo_id == repository.id
  end

  test "repository corrections stay within the project and cannot clear ownership" do
    task = insert(:task)
    project = Repo.get!(RintoPMO.Projects.Project, task.project_id)
    other = insert(:project_repo, project: project)

    for id <- [nil, UUIDv7.generate(), insert(:project_repo).id] do
      assert {:error, chset} = Tasks.update_task(task, %{repo_id: id})
      assert errors_on(chset).repo_id
      assert Tasks.get_task!(task.id).repo_id == task.repo_id
    end

    assert {:ok, updated} = Tasks.update_task(task, %{repo_id: other.id})
    assert updated.repo_id == other.id
    assert [filtered] = Tasks.list_tasks(%{repo_id: other.id})
    assert filtered.id == task.id
    assert Tasks.list_tasks(project, %{repo_id: task.repo_id}) == []
  end

  test "splits inherit a repository but may explicitly span repositories in the same project" do
    task = insert(:task)
    other = insert(:project_repo, project_id: task.project_id, project: nil)

    assert {:ok, cover} =
             Tasks.split_task(task, [
               %{title: "Original repo"},
               %{title: "Other repo", repo_id: other.id}
             ])

    assert Enum.map(cover.children, & &1.repo_id) == [task.repo_id, other.id]
    assert Enum.all?(cover.children, &(&1.requirement_id == task.requirement_id))

    untouched = insert(:task)

    assert {:error, :validation_error, _} =
             Tasks.split_task(untouched, [
               %{title: "Valid"},
               %{title: "Wrong project", repo_id: other.id}
             ])

    assert Tasks.get_task!(untouched.id).kind == :work
    assert Tasks.list_tasks(%{parent_id: untouched.id}) == []
  end

  test "referenced repositories cannot be deleted, including repositories with finished work" do
    task = insert(:task, status: :done)
    repository = Repo.get!(RintoPMO.Projects.ProjectRepo, task.repo_id)
    assert {:error, chset} = Projects.delete_project_repo(repository)
    assert errors_on(chset).id == ["is still referenced by tasks"]
    assert Tasks.get_task!(task.id).repo_id == repository.id

    assert {:ok, _} = Tasks.delete_task(task)
    assert {:ok, _} = Projects.delete_project_repo(repository)
  end

  test "legacy import refuses ambiguous repositories without creating any tasks" do
    stub_with(DocumentsMock, Documents)
    project = insert(:project)
    requirement = insert(:requirement, project: project)
    insert(:project_repo, project: project)
    insert(:project_repo, project: project)

    document =
      insert(:document,
        project: project,
        requirement_id: requirement.id,
        kind: :task,
        status: :formal
      )

    revision = insert(:document_revision, document: document)
    insert(:document_block, revision: revision, content: "## Work\n\nImplement this.")

    assert {:error, :validation_error, details} = Tasks.file_breakdown(document)
    assert details["errors"].repo_id == ["can't be blank"]
    assert Tasks.list_tasks(project, %{}) == []
    assert Repo.get!(RintoPMO.Documents.Document, document.id).status == :formal
  end
end
