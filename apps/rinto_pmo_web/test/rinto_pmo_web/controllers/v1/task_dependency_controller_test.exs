defmodule RintoPMOWeb.V1.TaskDependencyControllerTest do
  use RintoPMOWeb.ConnCase, async: true

  alias RintoPMO.Tasks.Dependency
  alias RintoPMO.TasksMock

  setup :verify_on_exit!

  defp expect_task(task) do
    expect(TasksMock, :get_task!, fn _id -> task end)
    task
  end

  describe "dependencies" do
    test "answers with both ends of the edges", %{conn: conn} do
      task = expect_task(insert(:task))
      prerequisite = insert(:task)
      dependent = insert(:task)
      prerequisite_id = prerequisite.id
      dependent_id = dependent.id

      expect(TasksMock, :list_dependencies, fn ^task -> [prerequisite] end)
      expect(TasksMock, :list_dependents, fn ^task -> [dependent] end)

      body = conn |> get(~p"/api/v1/tasks/#{task.id}/dependencies") |> json_response(200)

      assert [%{"id" => ^prerequisite_id}] = body["data"]["depends_on"]
      assert [%{"id" => ^dependent_id}] = body["data"]["dependents"]
    end

    test "adds an edge and answers with the graph around the task", %{conn: conn} do
      task = expect_task(insert(:task))
      prerequisite = insert(:task)
      prerequisite_id = prerequisite.id

      expect(TasksMock, :add_dependency, fn ^task, ^prerequisite_id ->
        {:ok, %Dependency{task_id: task.id, depends_on_id: prerequisite_id}}
      end)

      expect(TasksMock, :list_dependencies, fn ^task -> [prerequisite] end)
      expect(TasksMock, :list_dependents, fn ^task -> [] end)

      body =
        conn
        |> post(~p"/api/v1/tasks/#{task.id}/dependencies", %{"depends_on_id" => prerequisite_id})
        |> json_response(200)

      assert [%{"id" => ^prerequisite_id}] = body["data"]["depends_on"]
    end

    test "a cycle refusal names the loop rather than merely asserting one", %{conn: conn} do
      task = expect_task(insert(:task))
      other = insert(:task)
      other_id = other.id
      cycle = [task.id, other_id]

      expect(TasksMock, :add_dependency, fn ^task, ^other_id ->
        {:error, :dependency_cycle, %{cycle: cycle}}
      end)

      body =
        conn
        |> post(~p"/api/v1/tasks/#{task.id}/dependencies", %{"depends_on_id" => other_id})
        |> json_response(409)

      assert body["error"] == "dependency_cycle"
      assert body["details"]["cycle"] == cycle
    end

    test "an out-of-order refusal carries both ends and both days", %{conn: conn} do
      task = expect_task(insert(:task))
      other = insert(:task)
      other_id = other.id

      expect(TasksMock, :add_dependency, fn ^task, ^other_id ->
        {:error, :dependency_out_of_order,
         %{depends_on_id: other_id, depends_on_planned_start_on: ~D[2026-09-14]}}
      end)

      body =
        conn
        |> post(~p"/api/v1/tasks/#{task.id}/dependencies", %{"depends_on_id" => other_id})
        |> json_response(422)

      assert body["error"] == "dependency_out_of_order"
      assert body["details"]["depends_on_planned_start_on"] == "2026-09-14"
    end

    test "removes an edge", %{conn: conn} do
      task = expect_task(insert(:task))
      other = insert(:task)
      other_id = other.id

      expect(TasksMock, :remove_dependency, fn ^task, ^other_id -> :ok end)

      assert conn
             |> delete(~p"/api/v1/tasks/#{task.id}/dependencies/#{other_id}")
             |> response(204)
    end
  end
end
