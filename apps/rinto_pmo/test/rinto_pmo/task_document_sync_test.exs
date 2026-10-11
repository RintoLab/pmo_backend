defmodule RintoPMO.TaskDocumentSyncTest do
  use RintoPMO.DataCase, async: true

  alias RintoPMO.Documents
  alias RintoPMO.DocumentsMock
  alias RintoPMO.Tasks
  alias RintoPMO.Tasks.DocumentEntry
  alias RintoPMO.Tasks.Task

  setup do
    project = insert(:project)
    requirement = insert(:requirement, project: project, priority: 2)
    backend = insert(:project_repo, project: project)
    frontend = insert(:project_repo, project: project)

    document =
      insert(:document,
        project: project,
        requirement_id: requirement.id,
        kind: :task,
        status: :formal
      )

    revision = insert(:document_revision, document: document)

    insert(:document_block,
      revision: revision,
      content: "## Work\n\n- [ ] T001 Implement the endpoint."
    )

    item = %{
      "key" => "T001",
      "title" => "Endpoint",
      "description" => "Acceptance criteria",
      "repo_id" => backend.id
    }

    %{
      project: project,
      requirement: requirement,
      backend: backend,
      frontend: frontend,
      document: document,
      revision: revision,
      item: item
    }
  end

  test "analyzed requirements can synchronize tasks without becoming active", ctx do
    ctx.requirement |> Ecto.Changeset.change(status: :analyzed) |> Repo.update!()

    assert {:ok, result} =
             Tasks.sync_document(ctx.document, payload(ctx.revision, [ctx.item]))

    assert [%{action: :created}] = result.items
    assert RintoPMO.Requirements.get_requirement!(ctx.requirement.id).status == :analyzed
  end

  test "creates work in multiple repos and retries reuse IDs and execution data", ctx do
    second = %{ctx.item | "key" => "T002", "repo_id" => ctx.frontend.id}
    input = payload(ctx.revision, [ctx.item, second])
    assert {:ok, result} = Tasks.sync_document(ctx.document, input)
    assert Enum.map(result.items, & &1.action) == [:created, :created]
    [first, last] = Enum.map(result.items, & &1.task)
    assert first.repo_id == ctx.backend.id
    assert last.repo_id == ctx.frontend.id
    assert first.requirement_id == ctx.requirement.id
    assert first.document_id == ctx.document.id
    assert first.priority == 2

    assert {:ok, estimated} =
             Tasks.update_task(first, %{estimate: %{optimistic: 10, likely: 20, pessimistic: 30}})

    actor = insert(:actor)
    assert {:ok, claimed} = Tasks.claim_task(estimated, actor.id)
    assert {:ok, started} = Tasks.transition_task(claimed, :start, actor.id)
    assert {:ok, _} = Tasks.transition_task(started, :complete, actor.id, %{actual_minutes: 25})

    assert {:ok, repeated} = Tasks.sync_document(ctx.document, input)
    assert Enum.map(repeated.items, & &1.action) == [:unchanged, :unchanged]
    assert Enum.map(repeated.items, & &1.task.id) == [first.id, last.id]
    assert hd(repeated.items).task.status == :done
    assert hd(repeated.items).task.assignee_id == actor.id
    assert hd(repeated.items).task.estimate_likely == 20
    assert hd(repeated.items).task.actual_minutes == 25
    assert Repo.aggregate(Task, :count) == 2
    assert Repo.get!(RintoPMO.Documents.Document, ctx.document.id).status == :formal
  end

  test "new revisions update source changes but preserve manual edits to other fields", ctx do
    assert {:ok, %{items: [%{task: task}]}} =
             Tasks.sync_document(ctx.document, payload(ctx.revision, [ctx.item]))

    assert {:ok, _} = Tasks.update_task(task, %{title: "Manual title", difficulty: 5})
    next = insert_revision_after(ctx.revision, document: ctx.document)
    updated = %{ctx.item | "description" => "New criteria", "repo_id" => ctx.frontend.id}

    assert {:ok, %{items: [%{action: :updated, task: changed}]}} =
             Tasks.sync_document(ctx.document, payload(next, [updated]))

    assert changed.id == task.id
    assert changed.title == "Manual title"
    assert changed.description == "New criteria"
    assert changed.repo_id == ctx.frontend.id
    assert changed.difficulty == 5
  end

  test "a manual conflict rolls back newly created tasks and entries in the same batch", ctx do
    assert {:ok, %{items: [%{task: task}]}} =
             Tasks.sync_document(ctx.document, payload(ctx.revision, [ctx.item]))

    assert {:ok, _} = Tasks.update_task(task, %{title: "Manual title"})
    next = insert_revision_after(ctx.revision, document: ctx.document)
    changed = %{ctx.item | "title" => "Different source title"}
    new = %{ctx.item | "key" => "T002"}

    assert {:error, :task_sync_conflict, %{key: "T001", fields: ["title"]}} =
             Tasks.sync_document(ctx.document, payload(next, [new, changed]))

    assert Repo.aggregate(Task, :count) == 1
    assert Repo.aggregate(DocumentEntry, :count) == 1
    assert Tasks.get_task!(task.id).title == "Manual title"
  end

  test "started work and changed interpretations of the same revision are protected", ctx do
    assert {:ok, %{items: [%{task: task}]}} =
             Tasks.sync_document(ctx.document, payload(ctx.revision, [ctx.item]))

    changed = %{ctx.item | "title" => "Changed"}

    assert {:error, :task_sync_conflict, _} =
             Tasks.sync_document(ctx.document, payload(ctx.revision, [changed]))

    next = insert_revision_after(ctx.revision, document: ctx.document)
    actor = insert(:actor)
    assert {:ok, claimed} = Tasks.claim_task(task, actor.id)
    assert {:ok, _} = Tasks.transition_task(claimed, :start, actor.id)

    assert {:error, :task_sync_conflict, _} =
             Tasks.sync_document(ctx.document, payload(next, [changed]))

    assert Tasks.get_task!(task.id).title == "Endpoint"
  end

  test "stale revisions and invalid Repo ownership write nothing", ctx do
    next = insert_revision_after(ctx.revision, document: ctx.document)

    assert {:error, :stale_document, _} =
             Tasks.sync_document(ctx.document, payload(ctx.revision, [ctx.item]))

    wrong_repo = %{ctx.item | "key" => "T002", "repo_id" => insert(:project_repo).id}

    assert {:error, :validation_error, %{key: "T002"}} =
             Tasks.sync_document(ctx.document, payload(next, [ctx.item, wrong_repo]))

    assert Repo.aggregate(Task, :count) == 0
    assert Repo.aggregate(DocumentEntry, :count) == 0
  end

  test "omissions preserve tasks; deletion tombstones prevent resurrection", ctx do
    assert {:ok, %{items: [%{task: task}]}} =
             Tasks.sync_document(ctx.document, payload(ctx.revision, [ctx.item]))

    next = insert_revision_after(ctx.revision, document: ctx.document)
    another = %{ctx.item | "key" => "T002"}
    assert {:ok, _} = Tasks.sync_document(ctx.document, payload(next, [another]))
    assert Tasks.get_task!(task.id).status == :open
    assert {:ok, _} = Tasks.delete_task(task)

    assert {:error, :task_sync_conflict, %{key: "T001", task_id: nil}} =
             Tasks.sync_document(ctx.document, payload(next, [ctx.item]))

    assert Repo.aggregate(Task, :count) == 1
  end

  test "rejects malformed batches, repeated keys and execution fields", ctx do
    for input <- [
          payload(ctx.revision, []),
          payload(ctx.revision, [ctx.item, ctx.item]),
          payload(ctx.revision, [Map.put(ctx.item, "status", "done")]),
          payload(ctx.revision, [%{ctx.item | "key" => ""}]),
          %{"tasks" => [ctx.item]},
          payload(ctx.revision, [%{ctx.item | "title" => ""}])
        ] do
      assert {:error, %Ecto.Changeset{}} = Tasks.sync_document(ctx.document, input)
    end

    assert Repo.aggregate(Task, :count) == 0
  end

  test "requires an adopted task document in an active project and open leaf requirement", ctx do
    for attrs <- [
          %{kind: :spec},
          %{status: :draft},
          %{status: :applied},
          %{archived_at: DateTime.utc_now()},
          %{requirement_id: nil}
        ] do
      ctx.document |> Ecto.Changeset.change(attrs) |> Repo.update!()

      assert {:error, :validation_error, _} =
               Tasks.sync_document(ctx.document, payload(ctx.revision, [ctx.item]))

      Repo.get!(RintoPMO.Documents.Document, ctx.document.id)
      |> Ecto.Changeset.change(Map.take(Map.from_struct(ctx.document), Map.keys(attrs)))
      |> Repo.update!()
    end

    insert(:requirement, project: ctx.project, parent: ctx.requirement)

    assert {:error, :validation_error, _} =
             Tasks.sync_document(ctx.document, payload(ctx.revision, [ctx.item]))
  end

  test "archived projects and closed requirements cannot be synchronized", ctx do
    ctx.project |> Ecto.Changeset.change(status: :archived) |> Repo.update!()

    assert {:error, :validation_error, %{project_id: _}} =
             Tasks.sync_document(ctx.document, payload(ctx.revision, [ctx.item]))

    Repo.get!(RintoPMO.Projects.Project, ctx.project.id)
    |> Ecto.Changeset.change(status: :active)
    |> Repo.update!()

    ctx.requirement |> Ecto.Changeset.change(status: :completed) |> Repo.update!()

    assert {:error, :validation_error, %{requirement_id: _}} =
             Tasks.sync_document(ctx.document, payload(ctx.revision, [ctx.item]))

    assert Repo.aggregate(Task, :count) == 0
  end

  test "the legacy importer cannot duplicate synchronized work", ctx do
    stub_with(DocumentsMock, Documents)
    assert {:ok, _} = Tasks.sync_document(ctx.document, payload(ctx.revision, [ctx.item]))
    assert {:error, :task_sync_conflict, _} = Tasks.file_breakdown(ctx.document)
    assert Repo.aggregate(Task, :count) == 1
  end

  defp payload(revision, items), do: %{"base_revision_id" => revision.id, "tasks" => items}
end
