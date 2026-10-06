defmodule RintoPMOWeb.V1.TaskSyncControllerTest do
  use RintoPMOWeb.ConnCase, async: true

  setup do
    stub_with(RintoPMO.DocumentsMock, RintoPMO.Documents)
    stub_with(RintoPMO.TasksMock, RintoPMO.Tasks)
    project = insert(:project)
    requirement = insert(:requirement, project: project)
    repository = insert(:project_repo, project: project)

    document =
      insert(:document,
        project: project,
        requirement_id: requirement.id,
        kind: :task,
        status: :formal
      )

    revision = insert(:document_revision, document: document)

    input = %{
      base_revision_id: revision.id,
      tasks: [%{key: "T001", title: "Work", repo_id: repository.id}]
    }

    %{document: document, input: input, repository: repository, requirement: requirement}
  end

  test "sync derives scope from the document and responds with stable IDs", ctx do
    url = ~p"/api/v1/documents/#{ctx.document.id}/tasks/sync"
    created = ctx.conn |> post(url, ctx.input) |> json_response(200)
    assert [%{"key" => "T001", "action" => "created", "task" => task}] = created["data"]["items"]
    assert task["requirement_id"] == ctx.requirement.id
    assert task["repo_id"] == ctx.repository.id
    assert task["document_id"] == ctx.document.id
    repeated = ctx.conn |> post(url, ctx.input) |> json_response(200)
    assert [%{"action" => "unchanged", "task" => same}] = repeated["data"]["items"]
    assert same["id"] == task["id"]
  end

  test "stale reads return 409 and execution fields return 422", ctx do
    url = ~p"/api/v1/documents/#{ctx.document.id}/tasks/sync"

    assert %{"error" => "stale_document"} =
             ctx.conn
             |> post(url, %{ctx.input | base_revision_id: UUIDv7.generate()})
             |> json_response(409)

    bad = %{ctx.input | tasks: [Map.put(hd(ctx.input.tasks), :status, "done")]}
    assert %{"error" => "validation_error"} = ctx.conn |> post(url, bad) |> json_response(422)
    assert RintoPMO.Repo.aggregate(RintoPMO.Tasks.Task, :count) == 0
  end

  test "same-revision conflicts return their key and preserve the task", ctx do
    url = ~p"/api/v1/documents/#{ctx.document.id}/tasks/sync"
    ctx.conn |> post(url, ctx.input) |> json_response(200)
    input = %{ctx.input | tasks: [%{hd(ctx.input.tasks) | title: "Another interpretation"}]}
    result = ctx.conn |> post(url, input) |> json_response(409)
    assert result["error"] == "task_sync_conflict"
    assert result["details"]["key"] == "T001"
  end
end
