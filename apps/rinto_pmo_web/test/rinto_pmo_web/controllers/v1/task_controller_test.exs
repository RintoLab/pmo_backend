defmodule RintoPMOWeb.V1.TaskControllerTest do
  use RintoPMOWeb.ConnCase, async: true

  alias RintoPMO.ProjectsMock
  alias RintoPMO.TasksMock

  describe "index" do
    test "lists a project's tasks", %{conn: conn} do
      project = expect_project()
      task = insert(:task, project: project)
      task_id = task.id

      expect(TasksMock, :list_tasks, fn ^project, %{} -> [task] end)

      conn = get(conn, ~p"/api/v1/projects/#{project.slug}/tasks")

      assert [
               %{
                 "id" => ^task_id,
                 "status" => "open",
                 "kind" => "work",
                 "parent_id" => nil,
                 "estimate" => nil,
                 "unestimated_tasks" => nil
               }
             ] = json_response(conn, 200)["data"]
    end

    test "parses every filter, with `none` meaning the pool and the WBS roots", %{conn: conn} do
      project = expect_project()
      document = insert(:document, project: project)

      expect(TasksMock, :list_tasks, fn ^project, filter ->
        assert filter == %{
                 kind: :work,
                 status: :in_progress,
                 assignee_id: nil,
                 parent_id: nil,
                 document_id: document.id,
                 live: true,
                 overdue: false
               }

        []
      end)

      conn =
        get(
          conn,
          ~p"/api/v1/projects/#{project.slug}/tasks?kind=work&status=in_progress&assignee_id=none&parent_id=none&document_id=#{document.id}&live=true&overdue=false"
        )

      assert json_response(conn, 200)["data"] == []
    end

    test "rejects an unknown kind", %{conn: conn} do
      project = expect_project()

      conn = get(conn, ~p"/api/v1/projects/#{project.slug}/tasks?kind=nope")

      assert %{"details" => %{"kind" => ["is invalid"]}} = json_response(conn, 400)
    end

    test "rejects an unknown status", %{conn: conn} do
      project = expect_project()

      conn = get(conn, ~p"/api/v1/projects/#{project.slug}/tasks?status=nope")

      assert %{"error" => "bad_request", "details" => %{"status" => ["is invalid"]}} =
               json_response(conn, 400)
    end

    test "rejects a malformed assignee_id", %{conn: conn} do
      project = expect_project()

      conn = get(conn, ~p"/api/v1/projects/#{project.slug}/tasks?assignee_id=nope")

      assert %{"details" => %{"assignee_id" => ["is invalid"]}} = json_response(conn, 400)
    end
  end

  describe "create" do
    test "passes a three-point estimate through", %{conn: conn} do
      project = expect_project()

      task =
        insert(:task,
          project: project,
          estimate_optimistic: 120,
          estimate_likely: 240,
          estimate_pessimistic: 480
        )

      params = %{
        "title" => "Estimated",
        "estimate" => %{"optimistic" => 120, "likely" => 240, "pessimistic" => 480}
      }

      expect(TasksMock, :create_task, fn ^project, ^params -> {:ok, task} end)

      conn = post(conn, ~p"/api/v1/projects/#{project.slug}/tasks", params)

      assert %{"estimate" => %{"optimistic" => 120, "expected" => 260}} =
               json_response(conn, 201)["data"]
    end

    test "an invalid estimate is a 422 naming the field", %{conn: conn} do
      project = expect_project()

      expect(TasksMock, :create_task, fn ^project, _attrs ->
        {:error, :invalid_estimate, %{field: "likely", reason: "must be ordered"}}
      end)

      conn =
        post(conn, ~p"/api/v1/projects/#{project.slug}/tasks", %{
          "title" => "Backwards",
          "estimate" => %{"optimistic" => 480, "likely" => 240, "pessimistic" => 120}
        })

      assert %{
               "error" => "invalid_estimate",
               "details" => %{"field" => "likely", "reason" => "must be ordered"}
             } = json_response(conn, 422)
    end

    test "files a task under the project", %{conn: conn} do
      project = expect_project()
      task = insert(:task, project: project, title: "Wire the claim endpoint")
      params = %{"title" => "Wire the claim endpoint"}

      expect(TasksMock, :create_task, fn ^project, ^params -> {:ok, task} end)

      conn = post(conn, ~p"/api/v1/projects/#{project.slug}/tasks", params)

      assert %{"title" => "Wire the claim endpoint"} = json_response(conn, 201)["data"]
    end

    test "files a summary node", %{conn: conn} do
      project = expect_project()
      chunk = insert(:summary_task, project: project)
      params = %{"kind" => "summary", "title" => "Milestone 1"}

      expect(TasksMock, :create_task, fn ^project, ^params -> {:ok, chunk} end)

      conn = post(conn, ~p"/api/v1/projects/#{project.slug}/tasks", params)

      assert %{"kind" => "summary"} = json_response(conn, 201)["data"]
    end

    test "a cycle in the tree is a 409", %{conn: conn} do
      project = expect_project()
      cycle = [UUIDv7.generate(), UUIDv7.generate()]

      expect(TasksMock, :create_task, fn ^project, _attrs ->
        {:error, :dependency_cycle, %{cycle: cycle}}
      end)

      conn = post(conn, ~p"/api/v1/projects/#{project.slug}/tasks", %{"title" => "Loop"})

      assert %{"error" => "dependency_cycle", "details" => %{"cycle" => ^cycle}} =
               json_response(conn, 409)
    end

    test "surfaces validation errors", %{conn: conn} do
      project = expect_project()

      expect(TasksMock, :create_task, fn ^project, _attrs ->
        {:error,
         %RintoPMO.Tasks.Task{}
         |> Ecto.Changeset.change()
         |> Ecto.Changeset.add_error(:title, "can't be blank")}
      end)

      conn = post(conn, ~p"/api/v1/projects/#{project.slug}/tasks", %{})

      assert %{"error" => "validation_error", "details" => %{"title" => ["can't be blank"]}} =
               json_response(conn, 422)
    end
  end

  describe "stats" do
    test "returns the board's counts", %{conn: conn} do
      project = expect_project()
      actor = insert(:actor)
      actor_id = actor.id

      expect(TasksMock, :project_stats, fn ^project ->
        %{
          total: 3,
          unassigned: 1,
          overdue: 2,
          by_status: %{open: 1, in_progress: 2, done: 0, cancelled: 0},
          by_assignee: [
            %{actor_id: actor.id, counts: %{open: 0, in_progress: 2, done: 0, cancelled: 0}}
          ],
          estimate: %{
            total: %{optimistic: 120, likely: 240, pessimistic: 480, expected: 260},
            remaining: %{optimistic: 60, likely: 120, pessimistic: 240, expected: 130},
            unestimated_tasks: 1,
            unestimated_tasks_remaining: 1
          },
          actual: %{total: 90, unmeasured_tasks: 2}
        }
      end)

      conn = get(conn, ~p"/api/v1/projects/#{project.slug}/tasks/stats")

      assert %{
               "total" => 3,
               "unassigned" => 1,
               "overdue" => 2,
               "by_status" => %{"open" => 1, "in_progress" => 2, "cancelled" => 0},
               "by_assignee" => [%{"actor_id" => ^actor_id, "counts" => %{"in_progress" => 2}}],
               "estimate" => %{
                 "total" => %{"expected" => 260},
                 "remaining" => %{"optimistic" => 60},
                 "unestimated_tasks" => 1,
                 "unestimated_tasks_remaining" => 1
               },
               "actual" => %{"total" => 90, "unmeasured_tasks" => 2}
             } = json_response(conn, 200)["data"]
    end
  end

  describe "show and update" do
    test "shows a task by id, without a project in the path", %{conn: conn} do
      task = insert(:task)
      task_id = task.id

      expect(TasksMock, :get_task!, fn id ->
        assert id == task.id
        task
      end)

      conn = get(conn, ~p"/api/v1/tasks/#{task.id}")

      assert %{"id" => ^task_id} = json_response(conn, 200)["data"]
    end

    test "updates a task's wording", %{conn: conn} do
      task = insert(:task)
      updated = %{task | title: "Renamed"}
      params = %{"title" => "Renamed"}

      expect(TasksMock, :get_task!, fn _id -> task end)
      expect(TasksMock, :update_task, fn ^task, ^params -> {:ok, updated} end)

      conn = patch(conn, ~p"/api/v1/tasks/#{task.id}", params)

      assert %{"title" => "Renamed"} = json_response(conn, 200)["data"]
    end
  end

  describe "distribution" do
    test "assigns a task", %{conn: conn} do
      task = insert(:task)
      actor = insert(:actor)
      actor_id = actor.id
      assigned = %{task | assignee_id: actor.id, assigned_at: DateTime.utc_now()}

      expect(TasksMock, :get_task!, fn _id -> task end)
      expect(TasksMock, :assign_task, fn ^task, ^actor_id -> {:ok, assigned} end)

      conn = post(conn, ~p"/api/v1/tasks/#{task.id}/assign", %{"actor_id" => actor.id})

      assert %{"assignee_id" => ^actor_id} = json_response(conn, 200)["data"]
    end

    # Pulling, so the claimant is the caller. `assign` is the one that still
    # names somebody, because it pushes work at them.
    test "claims a task for the token holder", %{conn: conn, current_actor: actor} do
      task = insert(:task)
      actor_id = actor.id
      claimed = %{task | assignee_id: actor.id}

      expect(TasksMock, :get_task!, fn _id -> task end)
      expect(TasksMock, :claim_task, fn ^task, ^actor_id -> {:ok, claimed} end)

      conn = post(conn, ~p"/api/v1/tasks/#{task.id}/claim", %{"actor_id" => insert(:actor).id})

      assert %{"assignee_id" => ^actor_id} = json_response(conn, 200)["data"]
    end

    test "losing a claim race is a 409 naming the winner", %{conn: conn} do
      task = insert(:task)
      winner = insert(:actor)
      winner_id = winner.id

      expect(TasksMock, :get_task!, fn _id -> task end)

      expect(TasksMock, :claim_task, fn ^task, _actor_id ->
        {:error, :task_already_claimed, %{assignee_id: winner.id, status: :open}}
      end)

      conn = post(conn, ~p"/api/v1/tasks/#{task.id}/claim", %{})

      assert %{
               "error" => "task_already_claimed",
               "details" => %{"assignee_id" => ^winner_id}
             } = json_response(conn, 409)
    end

    test "releases a task back to the pool as the token's actor", %{
      conn: conn,
      current_actor: current_actor
    } do
      task = insert(:task, assignee: build(:actor))
      released = %{task | assignee_id: nil, assigned_at: nil}

      expect(TasksMock, :get_task!, fn _id -> task end)

      expect(TasksMock, :release_task, fn ^task, actor_id ->
        assert actor_id == current_actor.id
        {:ok, released}
      end)

      conn = post(conn, ~p"/api/v1/tasks/#{task.id}/release")

      assert %{"assignee_id" => nil} = json_response(conn, 200)["data"]
    end

    test "releasing somebody else's task is a 403", %{conn: conn} do
      owner = insert(:actor)
      task = insert(:task, assignee: owner)
      owner_id = owner.id

      expect(TasksMock, :get_task!, fn _id -> task end)

      expect(TasksMock, :release_task, fn ^task, _actor_id ->
        {:error, :task_not_yours, %{assignee_id: owner_id}}
      end)

      conn = post(conn, ~p"/api/v1/tasks/#{task.id}/release")

      assert %{
               "error" => "task_not_yours",
               "details" => %{"assignee_id" => ^owner_id}
             } = json_response(conn, 403)
    end
  end

  describe "delete" do
    test "removes a task", %{conn: conn} do
      task = insert(:task)

      expect(TasksMock, :get_task!, fn _id -> task end)
      expect(TasksMock, :delete_task, fn ^task -> {:ok, task} end)

      conn = delete(conn, ~p"/api/v1/tasks/#{task.id}")

      assert response(conn, 204)
    end

    test "a node with children is a 409", %{conn: conn} do
      chunk = insert(:summary_task)

      expect(TasksMock, :get_task!, fn _id -> chunk end)

      expect(TasksMock, :delete_task, fn ^chunk ->
        {:error, :task_state_conflict, %{kind: :summary, reason: "task still has children"}}
      end)

      conn = delete(conn, ~p"/api/v1/tasks/#{chunk.id}")

      assert %{
               "error" => "task_state_conflict",
               "details" => %{"reason" => "task still has children"}
             } = json_response(conn, 409)
    end
  end

  describe "split" do
    test "returns the cover and the children it created", %{conn: conn} do
      project = insert(:project)
      task = insert(:task, project: project)
      chunk = insert(:summary_task, project: project)
      child = insert(:task, project: project, parent: chunk)
      child_id = child.id
      chunk_id = chunk.id

      expect(TasksMock, :get_task!, fn _id -> task end)

      expect(TasksMock, :split_task, fn ^task, children ->
        assert children == [%{"title" => "Schema"}]
        {:ok, %{chunk | children: [child]}}
      end)

      conn =
        post(conn, ~p"/api/v1/tasks/#{task.id}/split", %{"children" => [%{"title" => "Schema"}]})

      assert %{
               "data" => %{"id" => ^chunk_id, "kind" => "summary"},
               "children" => [%{"id" => ^child_id}]
             } = json_response(conn, 200)
    end

    test "children is optional", %{conn: conn} do
      task = insert(:task)
      chunk = insert(:summary_task)

      expect(TasksMock, :get_task!, fn _id -> task end)
      expect(TasksMock, :split_task, fn ^task, [] -> {:ok, %{chunk | children: []}} end)

      conn = post(conn, ~p"/api/v1/tasks/#{task.id}/split")

      assert %{"children" => []} = json_response(conn, 200)
    end

    test "rejects a malformed children payload", %{conn: conn} do
      task = insert(:task)

      expect(TasksMock, :get_task!, fn _id -> task end)

      conn = post(conn, ~p"/api/v1/tasks/#{task.id}/split", %{"children" => "nope"})

      assert %{"details" => %{"children" => ["must be an array"]}} = json_response(conn, 400)
    end

    test "an unsplittable task is a 422 naming its status", %{conn: conn} do
      task = insert(:task, status: :done)

      expect(TasksMock, :get_task!, fn _id -> task end)

      expect(TasksMock, :split_task, fn ^task, [] ->
        {:error, :task_not_splittable, %{kind: :work, current_status: :done}}
      end)

      conn = post(conn, ~p"/api/v1/tasks/#{task.id}/split")

      assert %{
               "error" => "task_not_splittable",
               "details" => %{"current_status" => "done"}
             } = json_response(conn, 422)
    end
  end

  describe "status machine" do
    test "POST /tasks/:id/start fires :start", %{conn: conn, current_actor: actor} do
      task = expect_transition(:start, actor.id)

      conn = post(conn, ~p"/api/v1/tasks/#{task.id}/start")

      assert json_response(conn, 200)["data"]["id"] == task.id
    end

    test "POST /tasks/:id/complete fires :complete", %{conn: conn, current_actor: actor} do
      task = expect_transition(:complete, actor.id)

      conn = post(conn, ~p"/api/v1/tasks/#{task.id}/complete")

      assert json_response(conn, 200)["data"]["id"] == task.id
    end

    test "POST /tasks/:id/cancel fires :cancel", %{conn: conn, current_actor: actor} do
      task = expect_transition(:cancel, actor.id)

      conn = post(conn, ~p"/api/v1/tasks/#{task.id}/cancel")

      assert json_response(conn, 200)["data"]["id"] == task.id
    end

    test "POST /tasks/:id/reopen fires :reopen", %{conn: conn, current_actor: actor} do
      task = expect_transition(:reopen, actor.id)

      conn = post(conn, ~p"/api/v1/tasks/#{task.id}/reopen")

      assert json_response(conn, 200)["data"]["id"] == task.id
    end

    test "a summary node refuses an event with a 409 naming its kind", %{conn: conn} do
      chunk = insert(:summary_task)

      expect(TasksMock, :get_task!, fn _id -> chunk end)

      expect(TasksMock, :transition_task, fn ^chunk, :start, _actor_id, _attrs ->
        {:error, :task_state_conflict, %{kind: :summary, reason: "a summary node holds no work"}}
      end)

      conn = post(conn, ~p"/api/v1/tasks/#{chunk.id}/start")

      assert %{"error" => "task_state_conflict", "details" => %{"kind" => "summary"}} =
               json_response(conn, 409)
    end

    test "starting work assigned to somebody else is a 403", %{conn: conn} do
      owner = insert(:actor)
      task = insert(:task, assignee: owner)
      owner_id = owner.id

      expect(TasksMock, :get_task!, fn _id -> task end)

      expect(TasksMock, :transition_task, fn ^task, :start, _actor_id, _attrs ->
        {:error, :task_not_yours, %{assignee_id: owner_id}}
      end)

      conn = post(conn, ~p"/api/v1/tasks/#{task.id}/start")

      assert %{
               "error" => "task_not_yours",
               "details" => %{"assignee_id" => ^owner_id}
             } = json_response(conn, 403)
    end

    test "an impossible transition is a 409", %{conn: conn} do
      task = insert(:task)

      expect(TasksMock, :get_task!, fn _id -> task end)

      expect(TasksMock, :transition_task, fn ^task, :complete, _actor_id, _attrs ->
        {:error, :task_state_conflict, %{status: :open, event: :complete}}
      end)

      conn = post(conn, ~p"/api/v1/tasks/#{task.id}/complete")

      assert %{"error" => "task_state_conflict", "details" => %{"status" => "open"}} =
               json_response(conn, 409)
    end

    test "POST /tasks/:id/complete passes actual_minutes through", %{conn: conn} do
      task = insert(:task, status: :in_progress)

      expect(TasksMock, :get_task!, fn _id -> task end)

      expect(TasksMock, :transition_task, fn ^task, :complete, _actor_id, attrs ->
        assert attrs == %{"actual_minutes" => 90}
        {:ok, %{task | status: :done, actual_minutes: 90}}
      end)

      conn = post(conn, ~p"/api/v1/tasks/#{task.id}/complete", %{"actual_minutes" => 90})

      assert json_response(conn, 200)["data"]["actual_minutes"] == 90
    end
  end

  describe "estimation" do
    test "POST /tasks/:id/estimate answers with the queued job", %{conn: conn} do
      task = insert(:task)
      job = queued_job()

      expect(TasksMock, :get_task!, fn _id -> task end)
      expect(TasksMock, :request_estimation, fn ^task, :difficulty -> {:ok, job} end)

      conn = post(conn, ~p"/api/v1/tasks/#{task.id}/estimate", %{"kind" => "difficulty"})

      assert %{
               "id" => id,
               "worker" => "RintoPMO.Tasks.EstimationWorker",
               "status" => "running",
               "error" => nil
             } = json_response(conn, 202)["data"]

      # The job's id, not the task's. The task id is the one in the path.
      assert id == job.id
    end

    test "the kind picks the question", %{conn: conn} do
      task = insert(:task)
      job = queued_job()

      expect(TasksMock, :get_task!, fn _id -> task end)
      expect(TasksMock, :request_estimation, fn ^task, :time -> {:ok, job} end)

      conn = post(conn, ~p"/api/v1/tasks/#{task.id}/estimate", %{"kind" => "time"})

      assert json_response(conn, 202)
    end

    # Required rather than defaulted: there is no obvious default between the
    # two, and guessing would spend a model call on the question nobody asked.
    test "a missing or unknown kind is refused before anything is queued", %{conn: conn} do
      task = insert(:task)

      missing = post(conn, ~p"/api/v1/tasks/#{task.id}/estimate", %{})

      assert %{"error" => "bad_request", "details" => %{"kind" => ["is invalid"]}} =
               json_response(missing, 400)

      unknown = post(conn, ~p"/api/v1/tasks/#{task.id}/estimate", %{"kind" => "vibes"})
      assert %{"error" => "bad_request"} = json_response(unknown, 400)
    end

    test "relays a refusal", %{conn: conn} do
      task = insert(:task, estimate_optimistic: 1, estimate_likely: 2, estimate_pessimistic: 3)

      expect(TasksMock, :get_task!, fn _id -> task end)

      expect(TasksMock, :request_estimation, fn ^task, :time ->
        {:error, :nothing_to_estimate,
         %{kind: :time, reason: "every work item already has an estimate"}}
      end)

      conn = post(conn, ~p"/api/v1/tasks/#{task.id}/estimate", %{"kind" => "time"})

      assert %{"error" => "nothing_to_estimate"} = json_response(conn, 422)
    end

    # A double-click is answered like the first click. The context hands back
    # the job already queued, and nothing here can tell -- which is the point.
    test "a second ask is answered with the same job", %{conn: conn} do
      task = insert(:task)
      job = queued_job()

      expect(TasksMock, :get_task!, 2, fn _id -> task end)
      expect(TasksMock, :request_estimation, 2, fn ^task, :difficulty -> {:ok, job} end)

      first = post(conn, ~p"/api/v1/tasks/#{task.id}/estimate", %{"kind" => "difficulty"})
      second = post(conn, ~p"/api/v1/tasks/#{task.id}/estimate", %{"kind" => "difficulty"})

      assert json_response(first, 202)["data"] == json_response(second, 202)["data"]
    end
  end

  test "an unknown task is a 404", %{conn: conn} do
    id = UUIDv7.generate()

    expect(TasksMock, :get_task!, fn _id ->
      raise Ecto.NoResultsError, queryable: RintoPMO.Tasks.Task
    end)

    assert {404, _headers, _body} =
             assert_error_sent(:not_found, fn -> get(conn, ~p"/api/v1/tasks/#{id}") end)
  end

  # Every event carries the token's actor into the context, including the two
  # the context does not gate on it: which events are the assignee's is a domain
  # rule, and the controller's job is only to say truthfully who is asking.
  defp expect_transition(expected_event, expected_actor_id) do
    task = insert(:task)

    expect(TasksMock, :get_task!, fn _id -> task end)

    expect(TasksMock, :transition_task, fn ^task, event, actor_id, _attrs ->
      assert event == expected_event
      assert actor_id == expected_actor_id
      {:ok, task}
    end)

    task
  end

  # Built rather than inserted: the controller only reads it, and Oban's
  # queues are off in test so nothing would run it anyway.
  defp queued_job do
    %Oban.Job{
      id: 4242,
      worker: "RintoPMO.Tasks.EstimationWorker",
      queue: "default",
      state: "available",
      args: %{"task_id" => UUIDv7.generate(), "kind" => "difficulty"},
      errors: [],
      priority: 0,
      inserted_at: ~U[2026-08-22 09:00:00.000000Z],
      scheduled_at: ~U[2026-08-22 09:00:00.000000Z]
    }
  end

  defp expect_project do
    project = insert(:project)

    expect(ProjectsMock, :get_active_project_by_slug!, fn slug ->
      assert slug == project.slug
      project
    end)

    project
  end
end
