defmodule RintoPMO.RequirementEstimationTest do
  use RintoPMO.DataCase, async: true
  use Oban.Testing, repo: RintoPMO.Repo

  alias RintoPMO.Agent.TaskEstimatorMock
  alias RintoPMO.AIRoles
  alias RintoPMO.Requirements
  alias RintoPMO.Requirements.Estimation
  alias RintoPMO.Requirements.EstimationWorker
  alias RintoPMO.Tasks
  alias RintoPMO.Tasks.Task

  setup do
    project = insert(:project)
    root = insert(:requirement, project: project)
    leaf = insert(:requirement, project: project, parent: root)
    {:ok, project: project, root: root, leaf: leaf}
  end

  test "rollups count work exactly once, preserve zero and expose incomplete coverage", ctx do
    insert(:summary_task, project: ctx.project, requirement: ctx.leaf)

    insert(:task,
      project: ctx.project,
      requirement: ctx.leaf,
      estimate_optimistic: 0,
      estimate_likely: 0,
      estimate_pessimistic: 0
    )

    insert(:task, project: ctx.project, requirement: ctx.leaf)

    insert(:task,
      project: ctx.project,
      requirement: ctx.leaf,
      status: :done,
      estimate_optimistic: 30,
      estimate_likely: 60,
      estimate_pessimistic: 90
    )

    insert(:requirement, project: ctx.project, parent: ctx.root)
    insert(:task)
    workload = Requirements.get_requirement!(ctx.root.id).workload
    assert workload.task_count == 3
    assert workload.remaining_task_count == 2
    assert workload.unplanned_requirement_count == 1
    assert workload.estimate.total.expected == 60
    assert workload.estimate.remaining.expected == 0
    assert workload.estimate.unestimated_tasks == 1
    assert workload.estimate.unestimated_tasks_remaining == 1
    assert Requirements.get_requirement!(ctx.leaf.id).workload.unplanned_requirement_count == 0
  end

  test "unplanned requirements have null estimates, including in list responses", ctx do
    [root] = Requirements.list_requirements(ctx.project)
    assert root.workload.estimate.total == nil
    assert root.workload.estimate.remaining == nil
    assert root.workload.unplanned_requirement_count == 1
    assert root.workload.task_count == 0
  end

  test "batch selection expands leaves, deduplicates and explains skips", ctx do
    configure()
    task = insert(:task, project: ctx.project, requirement: ctx.leaf)
    empty = insert(:requirement, project: ctx.project, parent: ctx.root)
    {:ok, entries} = Estimation.request([ctx.root.id, ctx.leaf.id, ctx.root.id])
    assert length(entries) == 2
    assert %{job: nil, reason: :no_tasks} = Enum.find(entries, &(&1.requirement_id == empty.id))
    job = Enum.find(entries, &(&1.requirement_id == ctx.leaf.id)).job
    {:ok, [again]} = Estimation.request([ctx.leaf.id])
    assert again.job.id == job.id
    assert Enum.map(Estimation.targets(ctx.leaf.id), & &1.id) == [task.id]
    assert length(all_enqueued(worker: EstimationWorker)) == 1
  end

  test "invalid selection is rejected before enqueuing anything", ctx do
    configure()
    insert(:task, project: ctx.project, requirement: ctx.leaf)
    closed = insert(:requirement, status: :completed)

    for ids <- [
          nil,
          [],
          ["bad"],
          [UUIDv7.generate()],
          [ctx.leaf.id, closed.id],
          List.duplicate(ctx.leaf.id, 101)
        ] do
      assert {:error, :bad_request, _} = Estimation.request(ids)
    end

    assert all_enqueued(worker: EstimationWorker) == []
  end

  test "no-task requests need no AI role; estimated or finished work is skipped", ctx do
    assert {:ok, [%{reason: :no_tasks}]} = Estimation.request([ctx.leaf.id])
    task = insert(:task, project: ctx.project, requirement: ctx.leaf)
    assert {:error, :no_estimation_ai, _} = Estimation.request([ctx.leaf.id])

    assert {:ok, _} =
             Tasks.update_task(task, %{estimate: %{optimistic: 1, likely: 2, pessimistic: 3}})

    assert {:ok, [%{reason: :already_estimated}]} = Estimation.request([ctx.leaf.id])
    Repo.update_all(from(t in Task, where: t.id == ^task.id), set: [status: :done])
    assert {:ok, [%{reason: :no_pending_tasks}]} = Estimation.request([ctx.leaf.id])
  end

  test "worker supplies ancestor context and project history, estimates only pending missing work",
       ctx do
    configure()
    task = insert(:task, project: ctx.project, requirement: ctx.leaf)
    insert(:task, project: ctx.project, requirement: ctx.leaf, status: :done, actual_minutes: 42)
    insert(:task, actual_minutes: 99, status: :done)

    expect(TaskEstimatorMock, :estimate_time, fn input, opts ->
      assert Enum.map(input.tasks, & &1.id) == [task.id]
      assert Enum.map(input.context.requirements, & &1.id) == [ctx.root.id, ctx.leaf.id]
      assert [%{actual_minutes: 42}] = input.history
      assert opts[:model] == "flash"
      {:ok, [estimate(task)]}
    end)

    assert :ok = perform(ctx.leaf.id)
    assert Tasks.get_task!(task.id).estimate_likely == 60
    assert Requirements.get_requirement!(ctx.root.id).workload.estimate.total.expected == 65
  end

  test "worker never overwrites a concurrent manual estimate", ctx do
    configure()
    task = insert(:task, project: ctx.project, requirement: ctx.leaf)

    expect(TaskEstimatorMock, :estimate_time, fn _input, _opts ->
      {:ok, _} =
        Tasks.update_task(task, %{estimate: %{optimistic: 5, likely: 10, pessimistic: 15}})

      {:ok, [estimate(task)]}
    end)

    assert {:cancel, reason} = perform(ctx.leaf.id)
    assert reason =~ "changed"
    assert Tasks.get_task!(task.id).estimate_likely == 10
  end

  test "invalid, duplicate, missing or oversized results write none of the batch", ctx do
    configure()
    first = insert(:task, project: ctx.project, requirement: ctx.leaf)
    second = insert(:task, project: ctx.project, requirement: ctx.leaf)
    bad = Map.put(estimate(second), "pessimistic", 481)

    for items <- [
          [estimate(first)],
          [estimate(first), estimate(first)],
          [estimate(first), bad],
          [estimate(first), Map.put(estimate(second), "likely", -1)]
        ] do
      expect(TaskEstimatorMock, :estimate_time, fn _input, _opts -> {:ok, items} end)
      assert {:cancel, _reason} = perform(ctx.leaf.id)
      assert Tasks.get_task!(first.id).estimate_likely == nil
      assert Tasks.get_task!(second.id).estimate_likely == nil
    end
  end

  test "changed requirements or closed tasks reject stale model results", ctx do
    configure()
    task = insert(:task, project: ctx.project, requirement: ctx.leaf)

    expect(TaskEstimatorMock, :estimate_time, fn _input, _opts ->
      {:ok, _} = Requirements.update_requirement(ctx.leaf, %{description: "Scope changed"})
      {:ok, [estimate(task)]}
    end)

    assert {:cancel, reason} = perform(ctx.leaf.id)
    assert reason =~ "documents changed"
    assert Tasks.get_task!(task.id).estimate_likely == nil

    expect(TaskEstimatorMock, :estimate_time, fn _input, _opts ->
      Repo.update_all(from(t in Task, where: t.id == ^task.id), set: [status: :cancelled])
      {:ok, [estimate(task)]}
    end)

    assert {:cancel, _} = perform(ctx.leaf.id)
    assert Tasks.get_task!(task.id).estimate_likely == nil
  end

  test "queued jobs recheck project and ancestor state", ctx do
    configure()
    insert(:task, project: ctx.project, requirement: ctx.leaf)
    Repo.update!(change(ctx.root, status: :completed))
    assert {:cancel, _} = perform(ctx.leaf.id)
    assert {:error, :bad_request, _} = Estimation.request([ctx.leaf.id])
  end

  test "context reads document bodies from ancestors and rejects changed revisions", ctx do
    configure()
    task = insert(:task, project: ctx.project, requirement: ctx.leaf)
    document = insert(:document, project: ctx.project, requirement_id: ctx.root.id, kind: :spec)
    revision = insert(:document_revision, document: document, title: "Shared constraints")
    insert(:document_block, revision: revision, content: "Must support recovery")

    expect(TaskEstimatorMock, :estimate_time, fn input, _opts ->
      assert [%{kind: :spec, title: "Shared constraints", content: "Must support recovery"}] =
               input.context.documents

      insert_revision_after(revision, document: document, title: "Updated constraints")
      {:ok, [estimate(task)]}
    end)

    assert {:cancel, reason} = perform(ctx.leaf.id)
    assert reason =~ "documents changed"
    assert Tasks.get_task!(task.id).estimate_likely == nil
  end

  test "large requirements use bounded batches and retain earlier batches on later failure",
       ctx do
    configure()
    for _ <- 1..21, do: insert(:task, project: ctx.project, requirement: ctx.leaf)

    expect(TaskEstimatorMock, :estimate_time, fn input, _opts ->
      assert length(input.tasks) == 20
      {:ok, Enum.map(input.tasks, &estimate/1)}
    end)

    expect(TaskEstimatorMock, :estimate_time, fn input, _opts ->
      assert length(input.tasks) == 1
      {:error, :invalid_output}
    end)

    assert {:cancel, _} = perform(ctx.leaf.id)
    workload = Requirements.get_requirement!(ctx.leaf.id).workload
    assert workload.estimate.unestimated_tasks == 1
    assert workload.estimate.total.expected == 1300
  end

  defp configure do
    AIRoles.put_role("task_estimation", %{
      "provider" => "google",
      "model" => "flash",
      "thinking_level" => "off"
    })
  end

  defp perform(id), do: EstimationWorker.perform(%Oban.Job{args: %{"requirement_id" => id}})

  defp estimate(task),
    do: %{"id" => task.id, "optimistic" => 30, "likely" => 60, "pessimistic" => 120}
end
