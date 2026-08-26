defmodule RintoPMOWeb.V1.TaskSchemaJSONTest do
  @moduledoc """
  The served schema is only worth anything if it is still true, so these tests
  put it against the domain rather than against a copy of itself: the enums
  and the ceiling have to be the ones `RintoPMO.Tasks.Task` publishes, and
  every example it advertises has to be a body `RintoPMO.Tasks` accepts.

  That last one is the point of the file. An example that stopped working is
  the failure this endpoint exists to prevent, and it is not the kind of drift
  anybody notices by reading.
  """
  use RintoPMOWeb.ConnCase, async: true

  alias RintoPMO.Tasks
  alias RintoPMO.Tasks.Task
  alias RintoPMOWeb.V1.TaskSchemaJSON

  describe "GET /tasks/schema" do
    test "serves the three shapes a write can take", %{conn: conn} do
      conn = get(conn, ~p"/api/v1/tasks/schema")

      assert %{"create" => create, "update" => _update, "split" => split} =
               json_response(conn, 200)["data"]

      assert create["required"] == ["title"]
      assert create["properties"]["kind"]["enum"] == ["work", "summary"]
      assert split["properties"]["children"]["items"]["required"] == ["title"]
    end

    test "the update shape omits what only an event may move", %{conn: conn} do
      conn = get(conn, ~p"/api/v1/tasks/schema")
      update = json_response(conn, 200)["data"]["update"]

      refute Map.has_key?(update["properties"], "status")
      refute Map.has_key?(update["properties"], "kind")
      assert update["description"] =~ "ignored rather than refused"
    end

    test "a child of a split carries no parent, because the split answered that", %{conn: conn} do
      conn = get(conn, ~p"/api/v1/tasks/schema")
      child = json_response(conn, 200)["data"]["split"]["properties"]["children"]["items"]

      refute Map.has_key?(child["properties"], "parent_id")
      refute Map.has_key?(child["properties"], "kind")
      assert Map.has_key?(child["properties"], "planned_start_on")
    end

    test "the numbers are the domain's, not a copy of them", %{conn: conn} do
      conn = get(conn, ~p"/api/v1/tasks/schema")
      properties = json_response(conn, 200)["data"]["create"]["properties"]

      assert properties["difficulty"]["enum"] == Task.difficulties()
      assert properties["priority"]["enum"] == Task.priorities()

      assert properties["estimate"]["properties"]["pessimistic"]["maximum"] ==
               Task.estimate_ceiling()

      assert properties["estimate"]["description"] =~ "#{Task.estimate_ceiling()} minutes"
    end

    # They are dropped before the changeset sees them, so a client that used
    # them would be told nothing at all. Offering them in one shape out of
    # three is how that would start.
    test "the flat estimate columns are not offered anywhere", %{conn: conn} do
      conn = get(conn, ~p"/api/v1/tasks/schema")
      shapes = json_response(conn, 200)["data"]

      written = [
        shapes["create"]["properties"],
        shapes["update"]["properties"],
        shapes["split"]["properties"]["children"]["items"]["properties"]
      ]

      for properties <- written, {field, _schema} <- properties do
        refute String.starts_with?(field, "estimate_")
      end
    end
  end

  describe "the examples" do
    setup do
      %{project: insert(:project), shapes: TaskSchemaJSON.show(%{}).data}
    end

    test "create's example is a body the domain accepts", %{project: project, shapes: shapes} do
      [example] = shapes.create.examples

      assert {:ok, task} = Tasks.create_task(project, example)
      assert task.title == example["title"]
      assert task.priority == example["priority"]
      assert task.difficulty == example["difficulty"]
      assert task.estimate_likely == example["estimate"]["likely"]
    end

    test "update's example is a body the domain accepts", %{project: project, shapes: shapes} do
      [example] = shapes.update.examples
      task = insert(:task, project: project, planned_start_on: ~D[2026-09-01])

      assert {:ok, task} = Tasks.update_task(task, example)
      assert task.priority == 1
      assert task.planned_start_on == nil
    end

    test "split's example is a body the domain accepts", %{project: project, shapes: shapes} do
      [example] = shapes.split.examples
      task = insert(:task, project: project)

      assert {:ok, summary} = Tasks.split_task(task, example["children"])
      assert summary.kind == :summary

      assert Enum.map(summary.children, & &1.title) ==
               Enum.map(example["children"], & &1["title"])
    end
  end
end
