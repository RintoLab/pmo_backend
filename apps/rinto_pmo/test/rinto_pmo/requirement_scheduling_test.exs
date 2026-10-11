defmodule RintoPMO.RequirementSchedulingTest do
  use RintoPMO.DataCase, async: true

  alias RintoPMO.Requirements.Scheduling
  alias RintoPMO.Tasks
  alias RintoPMO.Tasks.Dependency

  @day ~D[2026-10-14]

  setup do
    project = insert(:project)
    root = insert(:requirement, project: project)
    %{project: project, root: root}
  end

  test "expands multiple levels and repositories, preserving existing plans and history", %{
    project: project,
    root: root
  } do
    branch = insert(:requirement, project: project, parent_id: root.id)
    leaf = insert(:requirement, project: project, parent_id: branch.id, priority: 1)
    sibling = insert(:requirement, project: project, parent_id: root.id)
    first = insert(:task, project: project, requirement: leaf)
    repo = insert(:project_repo, project: project)

    second =
      insert(:task,
        project: project,
        requirement: sibling,
        repo: repo,
        status: :in_progress,
        first_planned_on: ~D[2026-10-01]
      )

    scheduled =
      insert(:task,
        project: project,
        requirement: sibling,
        planned_start_on: ~D[2026-10-20],
        first_planned_on: ~D[2026-10-10]
      )

    done = insert(:task, project: project, requirement: leaf, status: :done)
    cancelled = insert(:task, project: project, requirement: leaf, status: :cancelled)
    unrelated = insert(:task, project: project)
    other_project = insert(:task)

    assert {:ok, result} = schedule(root.id)
    assert Enum.map(result.tasks, & &1.id) == Enum.sort([first.id, second.id])
    assert Enum.all?(result.tasks, &(&1.planned_start_on == @day))
    assert Enum.find(result.tasks, &(&1.id == first.id)).priority == 1
    assert Enum.find(result.tasks, &(&1.id == first.id)).estimate_likely == nil
    assert Repo.reload!(first).first_planned_on == @day
    assert Repo.reload!(second).first_planned_on == ~D[2026-10-01]

    assert Map.new(result.skipped, &{&1.task_id, &1.reason}) == %{
             scheduled.id => :already_scheduled,
             done.id => :not_live,
             cancelled.id => :not_live
           }

    for unchanged <- [scheduled, done, cancelled, unrelated, other_project] do
      actual = Repo.reload!(unchanged)
      assert actual.planned_start_on == unchanged.planned_start_on
      assert actual.first_planned_on == unchanged.first_planned_on
      assert actual.updated_at == unchanged.updated_at
    end

    assert {:ok, %{tasks: [], skipped: skipped}} = schedule(root.id, "2026-10-21")
    assert length(skipped) == 5
    assert Repo.reload!(first).planned_start_on == @day
  end

  test "validates internal dependencies against the final batch regardless of task order", %{
    project: project,
    root: root
  } do
    waiting = insert(:task, project: project, requirement: root)
    middle = insert(:task, project: project, requirement: root)
    prerequisite = insert(:task, project: project, requirement: root)
    assert {:ok, _} = Tasks.add_dependency(waiting, middle.id)
    assert {:ok, _} = Tasks.add_dependency(middle, prerequisite.id)

    assert {:ok, %{tasks: tasks}} = schedule(root.id)
    assert length(tasks) == 3
    assert Enum.all?(tasks, &(&1.planned_start_on == @day))
  end

  test "external unscheduled or later prerequisites roll back the entire batch", %{
    project: project,
    root: root
  } do
    independent = insert(:task, project: project, requirement: root)
    waiting = insert(:task, project: project, requirement: root)
    external = insert(:task)
    assert {:ok, _} = Tasks.add_dependency(waiting, external.id)

    for day <- [nil, Date.add(@day, 1)] do
      external |> Ecto.Changeset.change(planned_start_on: day) |> Repo.update!()
      assert {:error, :dependency_out_of_order, details} = schedule(root.id)
      assert details.task_id == waiting.id
      assert details.depends_on_id == external.id
      assert details.depends_on_planned_start_on == day

      for task <- [independent, waiting] do
        actual = Repo.reload!(task)
        assert actual.planned_start_on == nil
        assert actual.first_planned_on == nil
        assert actual.updated_at == task.updated_at
      end

      assert Repo.reload!(external).planned_start_on == day
    end
  end

  test "keeps scheduled tasks even within the requirement and checks their constraints", %{
    project: project,
    root: root
  } do
    prerequisite =
      insert(:task, project: project, requirement: root, planned_start_on: Date.add(@day, 1))

    waiting = insert(:task, project: project, requirement: root)
    assert {:ok, _} = Tasks.add_dependency(waiting, prerequisite.id)
    assert {:error, :dependency_out_of_order, _} = schedule(root.id)
    assert Repo.reload!(waiting).planned_start_on == nil
    assert Repo.reload!(prerequisite).planned_start_on == Date.add(@day, 1)
  end

  test "checks downstream tasks outside the batch without moving them", %{
    project: project,
    root: root
  } do
    prerequisite = insert(:task, project: project, requirement: root)
    waiting = insert(:task, planned_start_on: Date.add(@day, -1))
    # A previously completed prerequisite can have been reopened into the backlog.
    %{task_id: waiting.id, depends_on_id: prerequisite.id}
    |> Dependency.changeset()
    |> Repo.insert!()

    assert {:error, :dependency_out_of_order, details} = schedule(root.id)
    assert details.task_id == waiting.id
    assert Repo.reload!(prerequisite).planned_start_on == nil
    assert Repo.reload!(waiting).planned_start_on == Date.add(@day, -1)
  end

  test "accepts earlier, same-day and terminal external prerequisites", %{
    project: project,
    root: root
  } do
    waiting = insert(:task, project: project, requirement: root)

    for attrs <- [
          [planned_start_on: Date.add(@day, -1)],
          [planned_start_on: @day],
          [status: :done],
          [status: :cancelled]
        ] do
      prerequisite = insert(:task, attrs)
      assert {:ok, _} = Tasks.add_dependency(waiting, prerequisite.id)
    end

    assert {:ok, %{tasks: [_]}} = schedule(root.id)
  end

  test "excludes closed and archived descendant branches", %{project: project, root: root} do
    for attrs <- [
          [status: :completed],
          [status: :cancelled],
          [archived_at: DateTime.utc_now()]
        ] do
      branch = insert(:requirement, attrs ++ [project: project, parent_id: root.id])
      child = insert(:requirement, project: project, parent_id: branch.id)
      task = insert(:task, project: project, requirement: child)
      assert {:ok, %{tasks: [], skipped: []}} = schedule(root.id)
      assert Repo.reload!(task).planned_start_on == nil
      assert {:error, :bad_request, _} = schedule(child.id)
      assert {:error, :bad_request, _} = schedule(branch.id)
    end
  end

  test "rejects an archived project", %{project: project, root: root} do
    project |> Ecto.Changeset.change(status: :archived) |> Repo.update!()
    assert {:error, :bad_request, _} = schedule(root.id)
  end

  test "empty requirements return a successful no-op", %{root: root} do
    assert {:ok, %{requirement_id: id, planned_start_on: @day, tasks: [], skipped: []}} =
             schedule(root.id)

    assert id == root.id
  end

  defp schedule(id, day \\ Date.to_iso8601(@day)),
    do: Scheduling.request(id, %{"planned_start_on" => day})
end
