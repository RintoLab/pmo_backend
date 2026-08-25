defmodule RintoPMO.TasksDependenciesTest do
  use RintoPMO.DataCase, async: true

  alias RintoPMO.Tasks
  alias RintoPMO.Tasks.Task

  @monday ~D[2026-09-07]
  @next_monday ~D[2026-09-14]

  setup do
    %{project: insert(:project)}
  end

  defp task(project, attrs \\ []) do
    insert(:task, Keyword.put(attrs, :project, project))
  end

  describe "add_dependency/2" do
    test "records the edge, readable from both ends", %{project: project} do
      waiting = task(project)
      prerequisite = task(project)

      assert {:ok, _edge} = Tasks.add_dependency(waiting, prerequisite.id)

      assert [%Task{id: id}] = Tasks.list_dependencies(waiting)
      assert id == prerequisite.id

      assert [%Task{id: id}] = Tasks.list_dependents(prerequisite)
      assert id == waiting.id
    end

    test "refuses the same edge twice", %{project: project} do
      waiting = task(project)
      prerequisite = task(project)

      assert {:ok, _} = Tasks.add_dependency(waiting, prerequisite.id)
      assert {:error, changeset} = Tasks.add_dependency(waiting, prerequisite.id)
      assert errors_on(changeset) != %{}
    end

    test "refuses an edge to a task that is not there", %{project: project} do
      assert {:error, :task_not_found, _details} =
               Tasks.add_dependency(task(project), UUIDv7.generate())
    end

    test "allows an edge across two projects, unlike a parent" do
      release = task(insert(:project))
      infrastructure = task(insert(:project))

      # Deliberate, and not the same rule as `parent_id`, which refuses this.
      # A parent decides where a task lives; a dependency only constrains when
      # it happens, and scheduling here spans every project on purpose.
      assert {:ok, _} = Tasks.add_dependency(release, infrastructure.id)

      assert {:error, changeset} =
               Tasks.update_task(release, %{"parent_id" => insert(:summary_task).id})

      assert %{parent_id: ["belongs to another project"]} = errors_on(changeset)
    end

    test "refuses a summary node at either end", %{project: project} do
      cover = insert(:summary_task, project: project)
      work = task(project)

      assert {:error, :task_not_dependable, _} = Tasks.add_dependency(cover, work.id)
      assert {:error, :task_not_dependable, _} = Tasks.add_dependency(work, cover.id)
    end
  end

  describe "cycles" do
    test "a task cannot depend on itself", %{project: project} do
      one = task(project)

      assert {:error, :dependency_cycle, _} = Tasks.add_dependency(one, one.id)
    end

    test "the refusal names the loop it would have closed", %{project: project} do
      a = task(project)
      b = task(project)
      c = task(project)

      assert {:ok, _} = Tasks.add_dependency(b, a.id)
      assert {:ok, _} = Tasks.add_dependency(c, b.id)

      assert {:error, :dependency_cycle, %{cycle: cycle}} = Tasks.add_dependency(a, c.id)

      # Not merely "there would be a cycle": the tasks in it, by id.
      assert Enum.sort(cycle) == Enum.sort([a.id, b.id, c.id])
    end

    test "a diamond is not a cycle", %{project: project} do
      top = task(project)
      left = task(project)
      right = task(project)
      bottom = task(project)

      assert {:ok, _} = Tasks.add_dependency(left, top.id)
      assert {:ok, _} = Tasks.add_dependency(right, top.id)
      assert {:ok, _} = Tasks.add_dependency(bottom, left.id)
      assert {:ok, _} = Tasks.add_dependency(bottom, right.id)
    end
  end

  describe "the scheduling gate" do
    test "refuses an edge when the waiting task is already scheduled first", %{project: project} do
      waiting = task(project, planned_start_on: @monday)
      prerequisite = task(project, planned_start_on: @next_monday)

      assert {:error, :dependency_out_of_order, details} =
               Tasks.add_dependency(waiting, prerequisite.id)

      assert details.depends_on_id == prerequisite.id
      assert details.depends_on_planned_start_on == @next_monday
    end

    test "refuses an edge when the prerequisite is in the backlog", %{project: project} do
      waiting = task(project, planned_start_on: @monday)
      prerequisite = task(project, planned_start_on: nil)

      assert {:error, :dependency_out_of_order, _} =
               Tasks.add_dependency(waiting, prerequisite.id)
    end

    test "allows the same day: the week's own order puts the prerequisite first", %{
      project: project
    } do
      waiting = task(project, planned_start_on: @monday)
      prerequisite = task(project, planned_start_on: @monday)

      assert {:ok, _} = Tasks.add_dependency(waiting, prerequisite.id)
    end

    test "allows anything when the waiting task is in the backlog", %{project: project} do
      waiting = task(project, planned_start_on: nil)
      prerequisite = task(project, planned_start_on: @next_monday)

      assert {:ok, _} = Tasks.add_dependency(waiting, prerequisite.id)
    end

    test "refuses moving the waiting task ahead of its prerequisite", %{project: project} do
      prerequisite = task(project, planned_start_on: @next_monday)
      waiting = task(project, planned_start_on: @next_monday)
      {:ok, _} = Tasks.add_dependency(waiting, prerequisite.id)

      assert {:error, :dependency_out_of_order, _} =
               Tasks.update_task(waiting, %{"planned_start_on" => @monday})
    end

    test "refuses moving the prerequisite past what waits on it", %{project: project} do
      prerequisite = task(project, planned_start_on: @monday)
      waiting = task(project, planned_start_on: @monday)
      {:ok, _} = Tasks.add_dependency(waiting, prerequisite.id)

      assert {:error, :dependency_out_of_order, _} =
               Tasks.update_task(prerequisite, %{"planned_start_on" => @next_monday})
    end

    test "refuses pushing the prerequisite back to the backlog", %{project: project} do
      prerequisite = task(project, planned_start_on: @monday)
      waiting = task(project, planned_start_on: @monday)
      {:ok, _} = Tasks.add_dependency(waiting, prerequisite.id)

      assert {:error, :dependency_out_of_order, _} =
               Tasks.update_task(prerequisite, %{"planned_start_on" => nil})
    end

    test "an edit that does not touch the day is never refused for a conflict", %{
      project: project
    } do
      prerequisite = task(project, planned_start_on: @monday)
      waiting = task(project, planned_start_on: @monday)
      {:ok, _} = Tasks.add_dependency(waiting, prerequisite.id)

      assert {:ok, %Task{title: "Renamed"}} =
               Tasks.update_task(waiting, %{"title" => "Renamed"})
    end
  end

  describe "a dependency constrains only while it is live" do
    for status <- [:done, :cancelled] do
      test "a #{status} prerequisite holds nothing up", %{project: project} do
        prerequisite = task(project, planned_start_on: @next_monday, status: unquote(status))
        waiting = task(project, planned_start_on: @monday)

        assert {:ok, _} = Tasks.add_dependency(waiting, prerequisite.id)
      end
    end

    test "and neither does one that was never scheduled", %{project: project} do
      prerequisite = task(project, planned_start_on: nil, status: :done)
      waiting = task(project, planned_start_on: @monday)

      assert {:ok, _} = Tasks.add_dependency(waiting, prerequisite.id)
    end
  end

  describe "remove_dependency/2" do
    test "removes the edge, and absent is the same as removed", %{project: project} do
      waiting = task(project)
      prerequisite = task(project)
      {:ok, _} = Tasks.add_dependency(waiting, prerequisite.id)

      assert :ok = Tasks.remove_dependency(waiting, prerequisite.id)
      assert Tasks.list_dependencies(waiting) == []
      assert :ok = Tasks.remove_dependency(waiting, prerequisite.id)
    end

    test "deleting a task takes its edges with it", %{project: project} do
      waiting = task(project)
      prerequisite = task(project)
      {:ok, _} = Tasks.add_dependency(waiting, prerequisite.id)

      assert {:ok, _} = Tasks.delete_task(prerequisite)
      assert Tasks.list_dependencies(waiting) == []
    end
  end
end
