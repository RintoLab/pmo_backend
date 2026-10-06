defmodule RintoPMO.TaskRequirementsTest do
  use RintoPMO.DataCase, async: true

  alias RintoPMO.Calendar
  alias RintoPMO.Requirements
  alias RintoPMO.Schedule
  alias RintoPMO.Tasks
  alias RintoPMO.Tasks.Task

  test "starting activates only the draft leaf, while completion stays manual" do
    project = insert(:project)
    parent = insert(:requirement, project: project)
    requirement = insert(:requirement, project: project, parent: parent)
    actor = insert(:actor)
    task = insert(:task, project: project, requirement: requirement, assignee: actor)

    assert {:error, :task_not_yours} =
             normalize_error(Tasks.transition_task(task, :start, insert(:actor).id))

    assert Requirements.get_requirement!(requirement.id).status == :draft
    assert {:ok, started} = Tasks.transition_task(task, :start, actor.id)
    assert Requirements.get_requirement!(requirement.id).status == :active
    assert Requirements.get_requirement!(parent.id).status == :draft
    assert {:ok, _done} = Tasks.transition_task(started, :complete, actor.id)
    assert Requirements.get_requirement!(requirement.id).status == :active
  end

  test "starting preserves non-draft or archived markers without blocking the task" do
    actor = insert(:actor)

    for attrs <- [
          %{status: :active},
          %{status: :completed},
          %{status: :draft, archived_at: DateTime.utc_now()}
        ] do
      project = insert(:project)
      requirement = insert(:requirement, Map.put(attrs, :project, project))
      task = insert(:task, project: project, requirement: requirement, assignee: actor)
      assert {:ok, %{status: :in_progress}} = Tasks.transition_task(task, :start, actor.id)
      assert Requirements.get_requirement!(requirement.id).status == requirement.status
    end
  end

  defp normalize_error({:error, code, _details}), do: {:error, code}

  test "creation requires an open leaf requirement in the task's project" do
    project = insert(:project)
    parent = insert(:requirement, project: project)
    insert(:requirement, project: project, parent: parent)

    invalid = [
      nil,
      UUIDv7.generate(),
      insert(:requirement).id,
      parent.id,
      insert(:requirement, project: project, status: :completed).id,
      insert(:requirement, project: project, archived_at: DateTime.utc_now()).id
    ]

    for id <- invalid do
      assert {:error, chset} =
               Tasks.create_task(project, %{
                 title: "Work",
                 requirement_id: id,
                 repo_id: task_repo(project).id
               })

      assert errors_on(chset).requirement_id
    end

    requirement = insert(:requirement, project: project, priority: 2)

    assert {:ok, task} =
             Tasks.create_task(project, %{
               title: "Work",
               requirement_id: requirement.id,
               repo_id: task_repo(project).id
             })

    assert task.requirement_id == requirement.id
    assert task.priority == 2
    refute :priority in Task.__schema__(:fields)
  end

  test "priority changes affect existing tasks, filters, dependency reads and mutation responses" do
    project = insert(:project)
    requirement = insert(:requirement, project: project, priority: 4)
    task = insert(:task, project: project, requirement: requirement)
    other = insert(:task, project: project, requirement: requirement)
    assert {:ok, _edge} = Tasks.add_dependency(other, task.id)

    assert {:ok, _requirement} = Requirements.update_requirement(requirement, %{priority: 1})
    assert Tasks.get_task!(task.id).priority == 1
    assert length(Tasks.list_tasks(project, %{priority: 1})) == 2
    assert Tasks.list_tasks(project, %{priority: 4}) == []
    assert [%{priority: 1}] = Tasks.list_dependencies(other)
    assert [%{priority: 1}] = Tasks.list_dependents(task)
    assert {:ok, %{priority: 1}} = Tasks.update_task(task, %{title: "Updated using stale struct"})
    actor = insert(:actor)
    assert {:ok, %{priority: 1} = claimed} = Tasks.claim_task(task, actor.id)
    assert {:ok, %{priority: 1}} = Tasks.transition_task(claimed, :start, actor.id)
    assert [%{task: %{priority: 1}}] = Schedule.history(Date.utc_today(), Date.utc_today())

    assert {:error, chset} = Tasks.update_task(task, %{priority: 5})
    assert errors_on(chset).priority == ["is inherited from the requirement"]
  end

  test "schedule repacks when requirement priority changes" do
    project = insert(:project)
    week = Calendar.next_week(Calendar.current_week())

    first =
      insert(:task,
        project: project,
        priority: 2,
        planned_start_on: week,
        estimate_optimistic: 60,
        estimate_likely: 60,
        estimate_pessimistic: 60
      )

    second =
      insert(:task,
        project: project,
        priority: 4,
        planned_start_on: week,
        estimate_optimistic: 60,
        estimate_likely: 60,
        estimate_pessimistic: 60
      )

    assert [plan] = Schedule.pack(week, week)
    assert Enum.map(plan.allocations, & &1.task.id) == [first.id, second.id]
    requirement = Requirements.get_requirement!(second.requirement_id)
    assert {:ok, _} = Requirements.update_requirement(requirement, %{priority: 1})
    assert [plan] = Schedule.pack(week, week)
    assert Enum.map(plan.allocations, & &1.task.id) == [second.id, first.id]
  end

  test "a requirement with tasks cannot acquire child requirements" do
    project = insert(:project)
    task = insert(:task, project: project)

    assert {:error, chset} =
             Requirements.create_requirement(project, %{
               title: "Child",
               parent_id: task.requirement_id
             })

    assert errors_on(chset).parent_id == [
             "already has tasks; only leaf requirements can own tasks"
           ]
  end

  test "active requirements can be reprioritized, but content stays protected" do
    project = insert(:project)
    assert {:ok, draft} = Requirements.create_requirement(project, %{title: "Default"})
    assert draft.priority == 3
    requirement = insert(:requirement, project: project, status: :active)
    assert {:ok, updated} = Requirements.update_requirement(requirement, %{priority: 1})
    assert updated.priority == 1
    assert {:error, chset} = Requirements.update_requirement(requirement, %{title: "Changed"})
    assert errors_on(chset).status

    for priority <- [nil, 0, 6] do
      assert {:error, chset} = Requirements.update_requirement(requirement, %{priority: priority})
      assert errors_on(chset).priority
    end
  end
end
