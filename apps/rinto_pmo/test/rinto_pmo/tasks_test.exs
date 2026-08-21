defmodule RintoPMO.TasksTest do
  use RintoPMO.DataCase, async: true

  alias RintoPMO.Agent.WbsGeneratorMock
  alias RintoPMO.Conversations
  alias RintoPMO.ConversationsMock
  alias RintoPMO.Documents
  alias RintoPMO.DocumentsMock
  alias RintoPMO.Projects
  alias RintoPMO.ProjectsMock
  alias RintoPMO.Settings
  alias RintoPMO.Tasks
  alias RintoPMO.Tasks.Task

  describe "create_task/2" do
    test "creates an open, unassigned task under a project" do
      project = insert(:project)

      assert {:ok, %Task{} = task} =
               Tasks.create_task(project, %{
                 "title" => "Wire the claim endpoint",
                 "description" => "Follow docs/api-frontend-guide.md"
               })

      assert task.project_id == project.id
      assert task.status == :open
      assert task.assignee_id == nil
      assert task.assigned_at == nil
      assert task.started_at == nil
      assert task.completed_at == nil
    end

    test "creates a task already pointed at a spec and an owner" do
      project = insert(:project)
      document = insert(:document, project: project)
      actor = insert(:actor)

      assert {:ok, task} =
               Tasks.create_task(project, %{
                 "title" => "Implement §4",
                 "document_id" => document.id,
                 "assignee_id" => actor.id,
                 "due_on" => "2026-09-01"
               })

      assert task.document_id == document.id
      assert task.assignee_id == actor.id
      assert task.due_on == ~D[2026-09-01]
      assert task.assigned_at
    end

    test "requires a title" do
      project = insert(:project)

      assert {:error, changeset} = Tasks.create_task(project, %{})
      assert "can't be blank" in errors_on(changeset).title
    end

    test "rejects an unknown assignee" do
      project = insert(:project)

      assert {:error, changeset} =
               Tasks.create_task(project, %{
                 "title" => "Orphan",
                 "assignee_id" => UUIDv7.generate()
               })

      assert "does not exist" in errors_on(changeset).assignee_id
    end
  end

  describe "update_task/2" do
    test "updates wording without touching status" do
      task = insert(:task, status: :in_progress)

      assert {:ok, updated} = Tasks.update_task(task, %{"title" => "Renamed", "status" => "done"})

      assert updated.title == "Renamed"
      assert updated.status == :in_progress
    end
  end

  describe "list_tasks/2" do
    test "lists a project's tasks oldest first" do
      project = insert(:project)
      first = insert(:task, project: project)
      second = insert(:task, project: project)
      insert(:task)

      assert [first.id, second.id] == ids(Tasks.list_tasks(project, %{}))
    end

    test "filters by status, assignee, document, and liveness" do
      project = insert(:project)
      document = insert(:document, project: project)
      actor = insert(:actor)

      open = insert(:task, project: project)
      mine = insert(:task, project: project, assignee: actor, status: :in_progress)
      spec = insert(:task, project: project, document: document)
      done = insert(:task, project: project, status: :done)

      assert [mine.id] == ids(Tasks.list_tasks(project, %{status: :in_progress}))
      assert [mine.id] == ids(Tasks.list_tasks(project, %{assignee_id: actor.id}))
      assert [spec.id] == ids(Tasks.list_tasks(project, %{document_id: document.id}))
      assert [done.id] == ids(Tasks.list_tasks(project, %{live: false}))

      assert [open.id, spec.id] ==
               ids(Tasks.list_tasks(project, %{assignee_id: nil, live: true}))
    end

    test "overdue counts only unfinished work" do
      project = insert(:project)
      yesterday = Date.add(Date.utc_today(), -1)

      late = insert(:task, project: project, due_on: yesterday)
      insert(:task, project: project, due_on: yesterday, status: :done)
      insert(:task, project: project, due_on: Date.add(Date.utc_today(), 1))
      insert(:task, project: project)

      assert [late.id] == ids(Tasks.list_tasks(project, %{overdue: true}))
      assert length(Tasks.list_tasks(project, %{overdue: false})) == 3
    end
  end

  describe "assign_task/2" do
    test "assigns and stamps the handoff" do
      task = insert(:task)
      actor = insert(:actor)

      assert {:ok, assigned} = Tasks.assign_task(task, actor.id)
      assert assigned.assignee_id == actor.id
      assert assigned.assigned_at
    end

    test "overwrites the current assignee and restamps" do
      first = insert(:actor)
      second = insert(:actor)
      task = insert(:task, assignee: first, assigned_at: ~U[2020-01-01 00:00:00.000000Z])

      assert {:ok, reassigned} = Tasks.assign_task(task, second.id)
      assert reassigned.assignee_id == second.id
      assert DateTime.after?(reassigned.assigned_at, task.assigned_at)
    end

    test "refuses an unknown or malformed actor" do
      task = insert(:task)

      assert {:error, :validation_error, %{"actor_id" => ["does not exist"]}} =
               Tasks.assign_task(task, UUIDv7.generate())

      assert {:error, :validation_error, %{"actor_id" => ["is invalid"]}} =
               Tasks.assign_task(task, "nope")

      assert {:error, :validation_error, %{"actor_id" => ["is invalid"]}} =
               Tasks.assign_task(task, nil)
    end
  end

  describe "claim_task/2" do
    test "claims an unassigned task" do
      task = insert(:task)
      actor = insert(:actor)

      assert {:ok, claimed} = Tasks.claim_task(task, actor.id)
      assert claimed.assignee_id == actor.id
      assert claimed.assigned_at
    end

    test "only one of two concurrent claims wins" do
      task = insert(:task)
      first = insert(:actor)
      second = insert(:actor)

      assert {:ok, claimed} = Tasks.claim_task(task, first.id)

      # The loser still holds the pre-claim struct, which is exactly the race:
      # it read an unassigned task and is writing against that reading.
      assert {:error, :task_already_claimed, details} = Tasks.claim_task(task, second.id)
      assert details.assignee_id == claimed.assignee_id
    end

    test "refuses to claim finished work" do
      done = insert(:task, status: :done)
      cancelled = insert(:task, status: :cancelled)
      actor = insert(:actor)

      assert {:error, :task_state_conflict, %{status: :done}} = Tasks.claim_task(done, actor.id)

      assert {:error, :task_state_conflict, %{status: :cancelled}} =
               Tasks.claim_task(cancelled, actor.id)
    end

    test "refuses an unknown actor without touching the task" do
      task = insert(:task)

      assert {:error, :validation_error, _details} = Tasks.claim_task(task, UUIDv7.generate())
      assert Repo.get!(Task, task.id).assignee_id == nil
    end
  end

  describe "release_task/1" do
    test "returns a task to the pool while keeping its progress" do
      actor = insert(:actor)

      task =
        insert(:task,
          assignee: actor,
          status: :in_progress,
          started_at: ~U[2026-01-01 00:00:00.000000Z]
        )

      assert {:ok, released} = Tasks.release_task(task)
      assert released.assignee_id == nil
      assert released.assigned_at == nil
      assert released.status == :in_progress
      assert released.started_at == task.started_at
    end
  end

  describe "transition_task/2" do
    test "runs the happy path from open to done" do
      task = insert(:task, assignee: build(:actor))

      assert {:ok, started} = Tasks.transition_task(task, :start)
      assert started.status == :in_progress
      assert started.started_at

      assert {:ok, done} = Tasks.transition_task(started, :complete)
      assert done.status == :done
      assert done.completed_at
    end

    test "refuses to start a task nobody owns" do
      task = insert(:task)

      assert {:error, :task_state_conflict, details} = Tasks.transition_task(task, :start)
      assert details.reason == "task has no assignee"
    end

    test "refuses an event the current status has no edge for" do
      task = insert(:task, assignee: build(:actor))

      assert {:error, :task_state_conflict, %{status: :open, event: :complete}} =
               Tasks.transition_task(task, :complete)
    end

    test "cancelling keeps what was spent" do
      task =
        insert(:task,
          assignee: build(:actor),
          status: :in_progress,
          started_at: ~U[2026-01-01 00:00:00.000000Z]
        )

      assert {:ok, cancelled} = Tasks.transition_task(task, :cancel)
      assert cancelled.status == :cancelled
      assert cancelled.started_at == task.started_at
      assert cancelled.completed_at == nil
    end

    test "reopening drops the timestamps that claimed the task finished" do
      task =
        insert(:task,
          assignee: build(:actor),
          status: :done,
          started_at: ~U[2026-01-01 00:00:00.000000Z],
          completed_at: ~U[2026-01-02 00:00:00.000000Z]
        )

      assert {:ok, reopened} = Tasks.transition_task(task, :reopen)
      assert reopened.status == :open
      assert reopened.started_at == nil
      assert reopened.completed_at == nil
      assert reopened.assignee_id == task.assignee_id
    end
  end

  describe "summary nodes" do
    test "a summary takes its status from its children" do
      project = insert(:project)
      chunk = insert(:summary_task, project: project)

      assert status_of(project, chunk) == :open

      first = insert(:task, project: project, parent: chunk)
      insert(:task, project: project, parent: chunk)

      assert status_of(project, chunk) == :open

      {:ok, _started} = Tasks.transition_task(%{first | assignee_id: insert(:actor).id}, :start)
      assert status_of(project, chunk) == :in_progress
    end

    test "a chunk is done when every child landed, cancelled only when every child was dropped" do
      project = insert(:project)

      all_done = insert(:summary_task, project: project)
      insert(:task, project: project, parent: all_done, status: :done)
      insert(:task, project: project, parent: all_done, status: :done)

      mixed = insert(:summary_task, project: project)
      insert(:task, project: project, parent: mixed, status: :done)
      insert(:task, project: project, parent: mixed, status: :cancelled)

      dropped = insert(:summary_task, project: project)
      insert(:task, project: project, parent: dropped, status: :cancelled)

      partly = insert(:summary_task, project: project)
      insert(:task, project: project, parent: partly, status: :done)
      insert(:task, project: project, parent: partly, status: :open)

      assert status_of(project, all_done) == :done
      # The chunk landed; the cancelled part was dropped along the way.
      assert status_of(project, mixed) == :done
      assert status_of(project, dropped) == :cancelled
      assert status_of(project, partly) == :in_progress
    end

    test "rollup recurses through nested summaries" do
      project = insert(:project)
      top = insert(:summary_task, project: project)
      middle = insert(:summary_task, project: project, parent: top)
      insert(:task, project: project, parent: middle, status: :done)

      assert status_of(project, top) == :done
      assert Tasks.get_task!(top.id).status == :done
    end

    test "get_task! rolls up a summary fetched on its own" do
      project = insert(:project)
      chunk = insert(:summary_task, project: project)
      insert(:task, project: project, parent: chunk, status: :done)

      assert Tasks.get_task!(chunk.id).status == :done
      # The stored column is inert -- only the read path is authoritative.
      assert Repo.get!(Task, chunk.id).status == :open
    end

    test "a summary refuses everything that acts on work" do
      project = insert(:project)
      chunk = insert(:summary_task, project: project)
      actor = insert(:actor)

      assert {:error, :task_state_conflict, %{kind: :summary}} =
               Tasks.assign_task(chunk, actor.id)

      assert {:error, :task_state_conflict, %{kind: :summary}} = Tasks.claim_task(chunk, actor.id)
      assert {:error, :task_state_conflict, %{kind: :summary}} = Tasks.release_task(chunk)

      assert {:error, :task_state_conflict, %{kind: :summary}} =
               Tasks.transition_task(chunk, :start)

      assert {:error, :task_state_conflict, %{kind: :summary}} =
               Tasks.transition_task(chunk, :cancel)
    end

    test "a summary cannot be created holding an assignee" do
      project = insert(:project)

      assert {:error, changeset} =
               Tasks.create_task(project, %{
                 "kind" => "summary",
                 "title" => "Chunk",
                 "assignee_id" => insert(:actor).id
               })

      assert "a summary node cannot be assigned" in errors_on(changeset).assignee_id
    end

    test "kind is not a settable field" do
      task = insert(:task)

      assert {:ok, updated} = Tasks.update_task(task, %{"kind" => "summary"})
      assert updated.kind == :work
    end

    test "summary nodes are excluded from every count" do
      project = insert(:project)
      chunk = insert(:summary_task, project: project)
      insert(:task, project: project, parent: chunk, status: :done)
      insert(:task, project: project, parent: chunk)

      stats = Tasks.project_stats(project)

      assert stats.total == 2
      assert stats.by_status == %{open: 1, in_progress: 0, done: 1, cancelled: 0}
    end

    test "the WBS lists covers and work together, and roots are reachable" do
      project = insert(:project)
      chunk = insert(:summary_task, project: project)
      child = insert(:task, project: project, parent: chunk)
      loose = insert(:task, project: project)

      assert [chunk.id, child.id, loose.id] == ids(Tasks.list_tasks(project, %{}))
      assert [chunk.id, loose.id] == ids(Tasks.list_tasks(project, %{parent_id: nil}))
      assert [child.id] == ids(Tasks.list_tasks(project, %{parent_id: chunk.id}))
      assert [child.id, loose.id] == ids(Tasks.list_tasks(project, %{kind: :work}))
    end
  end

  describe "split_task/2" do
    test "promotes a job to a cover and files the jobs it turned out to be" do
      project = insert(:project)
      actor = insert(:actor)

      task =
        insert(:task,
          project: project,
          assignee: actor,
          status: :in_progress,
          started_at: ~U[2026-01-01 00:00:00.000000Z]
        )

      assert {:ok, summary} =
               Tasks.split_task(task, [
                 %{"title" => "Schema"},
                 %{"title" => "Endpoint", "assignee_id" => actor.id}
               ])

      assert summary.kind == :summary
      # A cover holds no assignee and no clock; what the job had accumulated
      # goes with the promotion rather than lingering as a claim about a chunk
      # that did not exist yet.
      assert summary.assignee_id == nil
      assert summary.assigned_at == nil
      assert summary.started_at == nil

      assert ["Schema", "Endpoint"] = Enum.map(summary.children, & &1.title)
      assert Enum.all?(summary.children, &(&1.parent_id == summary.id))
      assert Enum.all?(summary.children, &(&1.project_id == project.id))
      assert Enum.all?(summary.children, &(&1.kind == :work))

      # Two open children, so the cover reads open again.
      assert status_of(project, summary) == :open
    end

    test "promotes without children, leaving the tree to be filled in after" do
      project = insert(:project)
      task = insert(:task, project: project)
      existing = insert(:task, project: project, status: :done)

      assert {:ok, summary} = Tasks.split_task(task)
      assert summary.kind == :summary
      assert summary.children == []

      assert {:ok, _moved} = Tasks.update_task(existing, %{"parent_id" => summary.id})
      assert status_of(project, summary) == :done
    end

    test "refuses a cover and refuses finished work" do
      chunk = insert(:summary_task)
      done = insert(:task, status: :done)
      cancelled = insert(:task, status: :cancelled)

      assert {:error, :task_not_splittable, %{kind: :summary}} = Tasks.split_task(chunk)

      assert {:error, :task_not_splittable, %{current_status: :done}} = Tasks.split_task(done)

      assert {:error, :task_not_splittable, %{current_status: :cancelled}} =
               Tasks.split_task(cancelled)
    end

    test "an invalid child names its index and lands nothing" do
      task = insert(:task, status: :in_progress)

      assert {:error, :validation_error, details} =
               Tasks.split_task(task, [%{"title" => "Fine"}, %{"description" => "no title"}])

      assert %{"children" => %{"1" => %{title: ["can't be blank"]}}} = details

      # The whole split rolled back: still a job, and the valid child that had
      # already been inserted went with it.
      reloaded = Repo.get!(Task, task.id)
      assert reloaded.kind == :work
      assert reloaded.status == :in_progress
      assert Repo.aggregate(Task, :count, :id) == 1
    end

    test "a split task can be split again, one level down" do
      project = insert(:project)
      top = insert(:task, project: project)

      {:ok, top} = Tasks.split_task(top, [%{"title" => "Half"}])
      [half] = top.children

      assert {:ok, nested} = Tasks.split_task(half, [%{"title" => "Quarter"}])
      assert nested.kind == :summary
      assert nested.parent_id == top.id

      [quarter] = nested.children
      {:ok, _done} = Tasks.transition_task(%{quarter | assignee_id: insert(:actor).id}, :start)

      assert status_of(project, top) == :in_progress
    end
  end

  describe "estimates" do
    test "takes a whole three-point estimate and computes its expected value" do
      project = insert(:project)

      assert {:ok, task} =
               Tasks.create_task(project, %{
                 "title" => "Estimated",
                 "estimate" => %{"optimistic" => 120, "likely" => 240, "pessimistic" => 480}
               })

      assert task.estimate_optimistic == 120
      assert task.estimate_likely == 240
      assert task.estimate_pessimistic == 480
      # (120 + 4*240 + 480) / 6
      assert Task.expected(task) == 260
    end

    test "refuses a partial, unordered, or malformed estimate" do
      project = insert(:project)

      assert {:error, :invalid_estimate, %{field: "pessimistic", reason: reason}} =
               Tasks.create_task(project, %{
                 "title" => "Half",
                 "estimate" => %{"optimistic" => 1, "likely" => 2}
               })

      assert reason =~ "must be given with"

      assert {:error, :invalid_estimate, %{field: "likely", reason: "must be ordered"}} =
               Tasks.create_task(project, %{
                 "title" => "Backwards",
                 "estimate" => %{"optimistic" => 480, "likely" => 240, "pessimistic" => 600}
               })

      assert {:error, :invalid_estimate, %{field: "pessimistic", reason: "must be ordered"}} =
               Tasks.create_task(project, %{
                 "title" => "Backwards",
                 "estimate" => %{"optimistic" => 1, "likely" => 240, "pessimistic" => 2}
               })

      assert {:error, :invalid_estimate, %{field: "optimistic"}} =
               Tasks.create_task(project, %{
                 "title" => "Negative",
                 "estimate" => %{"optimistic" => -1, "likely" => 2, "pessimistic" => 3}
               })

      assert {:error, :invalid_estimate, %{field: "estimate"}} =
               Tasks.create_task(project, %{"title" => "Wrong shape", "estimate" => 240})
    end

    test "the raw columns are not writable, only the estimate object is" do
      project = insert(:project)

      assert {:ok, task} =
               Tasks.create_task(project, %{
                 "title" => "Sneaky",
                 "estimate_likely" => 240
               })

      assert task.estimate_likely == nil
    end

    test "an explicit null clears the estimate" do
      task =
        insert(:task,
          estimate_optimistic: 1,
          estimate_likely: 2,
          estimate_pessimistic: 3
        )

      assert {:ok, cleared} = Tasks.update_task(task, %{"estimate" => nil})
      assert cleared.estimate_optimistic == nil
      assert Task.expected(cleared) == nil
    end

    test "a summary node takes no estimate of its own" do
      chunk = insert(:summary_task)

      assert {:error, :invalid_estimate, %{field: "estimate", reason: reason}} =
               Tasks.update_task(chunk, %{
                 "estimate" => %{"optimistic" => 1, "likely" => 2, "pessimistic" => 3}
               })

      assert reason =~ "from its children"
    end

    test "a cover sums the estimates under it and counts what it had to skip" do
      project = insert(:project)
      chunk = insert(:summary_task, project: project)

      insert(:task,
        project: project,
        parent: chunk,
        estimate_optimistic: 60,
        estimate_likely: 120,
        estimate_pessimistic: 240
      )

      insert(:task,
        project: project,
        parent: chunk,
        estimate_optimistic: 30,
        estimate_likely: 60,
        estimate_pessimistic: 90
      )

      insert(:task, project: project, parent: chunk)

      rolled = Tasks.get_task!(chunk.id)

      assert rolled.estimate_optimistic == 90
      assert rolled.estimate_likely == 180
      assert rolled.estimate_pessimistic == 330
      # The sum covers two of three children, and says so.
      assert rolled.unestimated_tasks == 1
    end

    test "a cover with nothing estimated under it reports no estimate, not zero" do
      project = insert(:project)
      chunk = insert(:summary_task, project: project)
      insert(:task, project: project, parent: chunk)

      rolled = Tasks.get_task!(chunk.id)

      assert rolled.estimate_optimistic == nil
      assert rolled.unestimated_tasks == 1
    end

    test "the sum recurses through nested covers" do
      project = insert(:project)
      top = insert(:summary_task, project: project)
      middle = insert(:summary_task, project: project, parent: top)

      insert(:task,
        project: project,
        parent: middle,
        estimate_optimistic: 10,
        estimate_likely: 20,
        estimate_pessimistic: 30
      )

      insert(:task,
        project: project,
        parent: top,
        estimate_optimistic: 5,
        estimate_likely: 10,
        estimate_pessimistic: 15
      )

      rolled = Tasks.get_task!(top.id)

      assert rolled.estimate_optimistic == 15
      assert rolled.estimate_likely == 30
      assert rolled.estimate_pessimistic == 45
      assert rolled.unestimated_tasks == 0
    end

    test "splitting drops the guess made before anyone knew the parts" do
      task =
        insert(:task,
          estimate_optimistic: 60,
          estimate_likely: 120,
          estimate_pessimistic: 240
        )

      assert {:ok, summary} =
               Tasks.split_task(task, [
                 %{
                   "title" => "Half",
                   "estimate" => %{"optimistic" => 30, "likely" => 60, "pessimistic" => 120}
                 },
                 # The raw column is not castable on a child either.
                 %{"title" => "Other half", "estimate_optimistic" => 30}
               ])

      stored = Repo.get!(Task, summary.id)
      assert stored.estimate_optimistic == nil

      [first, second] = summary.children
      assert first.estimate_optimistic == 30
      assert second.estimate_optimistic == nil

      # ... and the cover now reports what its parts are worth.
      assert Tasks.get_task!(summary.id).estimate_optimistic == 30
      assert Tasks.get_task!(summary.id).unestimated_tasks == 1
    end

    test "a child with a broken estimate names its index and rolls the split back" do
      task = insert(:task)

      assert {:error, :invalid_estimate, %{field: "likely", child: 1}} =
               Tasks.split_task(task, [
                 %{"title" => "Fine"},
                 %{
                   "title" => "Backwards",
                   "estimate" => %{"optimistic" => 9, "likely" => 2, "pessimistic" => 3}
                 }
               ])

      assert Repo.get!(Task, task.id).kind == :work
      assert Repo.aggregate(Task, :count, :id) == 1
    end
  end

  describe "delete_task/1 and automatic demotion" do
    test "deleting the last child turns the cover back into a job" do
      project = insert(:project)
      task = insert(:task, project: project)

      {:ok, summary} = Tasks.split_task(task, [%{"title" => "Only"}])
      [only] = summary.children

      assert {:ok, _deleted} = Tasks.delete_task(only)

      demoted = Repo.get!(Task, summary.id)
      assert demoted.kind == :work
      assert demoted.status == :open
      assert Tasks.get_task!(summary.id).kind == :work
    end

    test "deleting a child that is not the last leaves the cover alone" do
      project = insert(:project)
      task = insert(:task, project: project)

      {:ok, summary} = Tasks.split_task(task, [%{"title" => "One"}, %{"title" => "Two"}])
      [one, _two] = summary.children

      assert {:ok, _deleted} = Tasks.delete_task(one)
      assert Repo.get!(Task, summary.id).kind == :summary
    end

    test "moving the last child away empties the cover just as deleting does" do
      project = insert(:project)
      task = insert(:task, project: project)
      elsewhere = insert(:summary_task, project: project)

      {:ok, summary} = Tasks.split_task(task, [%{"title" => "Only"}])
      [only] = summary.children

      assert {:ok, _moved} = Tasks.update_task(only, %{"parent_id" => elsewhere.id})
      assert Repo.get!(Task, summary.id).kind == :work
    end

    test "demotion resets a status that went inert at the split" do
      project = insert(:project)
      actor = insert(:actor)
      task = insert(:task, project: project, assignee: actor)

      {:ok, started} = Tasks.transition_task(task, :start)
      assert started.status == :in_progress

      {:ok, summary} = Tasks.split_task(started, [%{"title" => "Only"}])
      [only] = summary.children
      {:ok, _deleted} = Tasks.delete_task(only)

      # The pre-split `in_progress` does not come back to life weeks later.
      demoted = Repo.get!(Task, summary.id)
      assert demoted.status == :open
      assert demoted.assignee_id == nil
      assert demoted.started_at == nil
    end

    test "a cover that never had children stays a cover" do
      project = insert(:project)
      chunk = insert(:summary_task, project: project)
      loose = insert(:task, project: project)

      # Nothing was emptied, so nothing is demoted: a top-down breakdown that
      # has not been filled in is still a breakdown.
      assert {:ok, _moved} = Tasks.update_task(loose, %{"parent_id" => chunk.id})
      assert Repo.get!(Task, chunk.id).kind == :summary

      {:ok, empty} = Tasks.split_task(insert(:task, project: project))
      assert Repo.get!(Task, empty.id).kind == :summary
    end

    test "refuses to delete a node that still has children" do
      task = insert(:task)
      {:ok, summary} = Tasks.split_task(task, [%{"title" => "Child"}])

      assert {:error, :task_state_conflict, %{reason: "task still has children"}} =
               Tasks.delete_task(summary)

      assert Repo.get(Task, summary.id)
    end

    test "deleting a root touches nothing else" do
      project = insert(:project)
      task = insert(:task, project: project)
      other = insert(:task, project: project)

      assert {:ok, _deleted} = Tasks.delete_task(task)
      assert [other.id] == ids(Tasks.list_tasks(project, %{}))
    end
  end

  describe "parenting" do
    test "a parent must be a summary node in the same project" do
      project = insert(:project)
      work = insert(:task, project: project)
      elsewhere = insert(:summary_task)

      assert {:error, changeset} =
               Tasks.create_task(project, %{"title" => "Child", "parent_id" => work.id})

      assert "must be a summary node" in errors_on(changeset).parent_id

      assert {:error, changeset} =
               Tasks.create_task(project, %{"title" => "Child", "parent_id" => elsewhere.id})

      assert "belongs to another project" in errors_on(changeset).parent_id

      assert {:error, changeset} =
               Tasks.create_task(project, %{"title" => "Child", "parent_id" => UUIDv7.generate()})

      assert "does not exist" in errors_on(changeset).parent_id
    end

    test "a subtree cannot be moved under itself" do
      project = insert(:project)
      top = insert(:summary_task, project: project)
      middle = insert(:summary_task, project: project, parent: top)

      assert {:error, :dependency_cycle, %{cycle: cycle}} =
               Tasks.update_task(top, %{"parent_id" => middle.id})

      assert top.id in cycle

      assert {:error, :dependency_cycle, _details} =
               Tasks.update_task(top, %{"parent_id" => top.id})
    end

    test "moving a subtree to a legitimate new parent works" do
      project = insert(:project)
      first = insert(:summary_task, project: project)
      second = insert(:summary_task, project: project)
      child = insert(:task, project: project, parent: first, status: :done)

      assert {:ok, moved} = Tasks.update_task(child, %{"parent_id" => second.id})
      assert moved.parent_id == second.id
      assert status_of(project, first) == :open
      assert status_of(project, second) == :done
    end
  end

  describe "project_stats/1 estimates" do
    test "reports what the project was worth and what is left" do
      project = insert(:project)

      insert(:task,
        project: project,
        estimate_optimistic: 60,
        estimate_likely: 120,
        estimate_pessimistic: 240
      )

      insert(:task,
        project: project,
        status: :done,
        estimate_optimistic: 30,
        estimate_likely: 60,
        estimate_pessimistic: 90
      )

      insert(:task, project: project)
      insert(:task, project: project, status: :done)

      %{estimate: estimate} = Tasks.project_stats(project)

      assert estimate.total == %{
               optimistic: 90,
               likely: 180,
               pessimistic: 330,
               expected: round((90 + 4 * 180 + 330) / 6)
             }

      assert estimate.remaining == %{
               optimistic: 60,
               likely: 120,
               pessimistic: 240,
               expected: 130
             }

      assert estimate.unestimated_tasks == 2
      assert estimate.unestimated_tasks_remaining == 1
    end

    test "reports no estimate rather than zero when nobody estimated anything" do
      project = insert(:project)
      insert(:task, project: project)

      %{estimate: estimate} = Tasks.project_stats(project)

      assert estimate.total == nil
      assert estimate.remaining == nil
      assert estimate.unestimated_tasks == 1
    end

    test "covers contribute nothing of their own to the totals" do
      project = insert(:project)
      chunk = insert(:summary_task, project: project)

      insert(:task,
        project: project,
        parent: chunk,
        estimate_optimistic: 10,
        estimate_likely: 20,
        estimate_pessimistic: 30
      )

      %{estimate: estimate, total: total} = Tasks.project_stats(project)

      assert total == 1
      assert estimate.total.optimistic == 10
      assert estimate.unestimated_tasks == 0
    end
  end

  describe "project_stats/1" do
    test "counts by status and by assignee, and ignores other projects" do
      project = insert(:project)
      first = insert(:actor)
      second = insert(:actor)

      insert(:task, project: project)
      insert(:task, project: project)
      insert(:task, project: project, assignee: first, status: :in_progress)
      insert(:task, project: project, assignee: first, status: :done)
      insert(:task, project: project, assignee: second, status: :in_progress)
      insert(:task, status: :done)

      stats = Tasks.project_stats(project)

      assert stats.total == 5
      assert stats.unassigned == 2

      assert stats.by_status == %{open: 2, in_progress: 2, done: 1, cancelled: 0}

      by_assignee = Map.new(stats.by_assignee, &{&1.actor_id, &1.counts})
      assert map_size(by_assignee) == 2
      assert by_assignee[first.id][:in_progress] == 1
      assert by_assignee[first.id][:done] == 1
      assert by_assignee[first.id][:open] == 0
      assert by_assignee[second.id][:in_progress] == 1
    end

    test "counts only unfinished work as overdue" do
      project = insert(:project)
      yesterday = Date.add(Date.utc_today(), -1)

      insert(:task, project: project, due_on: yesterday)
      insert(:task, project: project, due_on: yesterday, status: :in_progress)
      insert(:task, project: project, due_on: yesterday, status: :done)
      insert(:task, project: project, due_on: yesterday, status: :cancelled)
      insert(:task, project: project)

      assert Tasks.project_stats(project).overdue == 2
    end

    test "reports zeroes for an empty project" do
      stats = Tasks.project_stats(insert(:project))

      assert stats.total == 0
      assert stats.unassigned == 0
      assert stats.overdue == 0
      assert stats.by_assignee == []
      assert stats.by_status == %{open: 0, in_progress: 0, done: 0, cancelled: 0}
    end
  end

  # The other end of decomposition: the document somebody adopted becomes the
  # work. The real `Documents` runs here rather than a mock, because what is
  # being tested is that two contexts move together -- tasks appear and the
  # document is spent, or neither.
  describe "file_breakdown/1" do
    setup do
      stub_with(DocumentsMock, Documents)
      stub_with(ProjectsMock, Projects)
      stub_with(ConversationsMock, Conversations)
      insert(:default_project)
      :ok
    end

    test "makes a summary over its tasks, and a plain task for a chunk with none" do
      project = insert(:project)

      breakdown =
        adopted(project, """
        ## 灰度发布

        分两步走。

        ### 接入十分之一流量

        先切 10%。

        ### 加监控看板

        ## 把回滚做成一个开关

        现在要手动改配置。
        """)

      assert {:ok, filed} = Tasks.file_breakdown(breakdown)

      assert [chunk, first, second, standalone] = filed

      assert Enum.map(filed, & &1.title) ==
               ["灰度发布", "接入十分之一流量", "加监控看板", "把回滚做成一个开关"]

      assert chunk.kind == :summary
      assert chunk.description == "分两步走。"
      assert first.kind == :work
      assert first.parent_id == chunk.id
      assert first.description == "先切 10%。"
      assert second.parent_id == chunk.id
      assert second.description == nil

      # A chunk nobody broke down further is one job, not a cover over one job.
      assert standalone.kind == :work
      assert standalone.parent_id == nil
      assert standalone.description == "现在要手动改配置。"

      assert Enum.all?(filed, &(&1.project_id == project.id))
      assert Enum.all?(filed, &(&1.status == :open))
      assert Enum.all?(filed, &(&1.assignee_id == nil))
      assert Enum.all?(filed, &(&1.estimate_optimistic == nil))
    end

    # The spec somebody implements against is the design that was broken down,
    # not the list of work it produced.
    test "points the tasks at the document the breakdown came from" do
      project = insert(:project)
      actor = insert(:actor, kind: :ai, provider: "google", model: "flash", thinking_level: "off")
      {:ok, _settings} = Settings.put_actor("decomposition_actor", actor.id)

      {:ok, source} =
        Documents.create_document(%{
          title: "上线方案",
          project_id: project.id,
          actor_id: actor.id,
          markdown: "## 灰度\n\n先接十分之一。"
        })

      {:ok, source} = Documents.formalize_document(source)
      {:ok, attempt} = Documents.request_decomposition(source)

      expect(WbsGeneratorMock, :generate, fn _input, _opts ->
        {:ok, "## 灰度发布\n\n### 接入十分之一流量\n"}
      end)

      :ok = Documents.run_decomposition(attempt)

      breakdown = Documents.breakdown_of(source)
      {:ok, breakdown} = Documents.formalize_document(breakdown)

      assert {:ok, filed} = Tasks.file_breakdown(breakdown)
      assert Enum.all?(filed, &(&1.document_id == source.id))
    end

    # Written by hand rather than generated: no source, and no less fileable.
    test "leaves the spec pointer empty when nothing generated the document" do
      breakdown = adopted(insert(:project), "## 一件活\n")

      assert {:ok, [task]} = Tasks.file_breakdown(breakdown)
      assert task.document_id == nil
    end

    test "spends the document, so it cannot be filed twice" do
      breakdown = adopted(insert(:project), "## 一件活\n")

      assert {:ok, _filed} = Tasks.file_breakdown(breakdown)
      assert Documents.get_document!(breakdown.id).status == :applied

      assert {:error, :document_not_formal, %{status: :applied}} =
               Tasks.file_breakdown(Documents.get_document!(breakdown.id))
    end

    test "refuses a document nobody has adopted" do
      project = insert(:project)

      {:ok, draft} =
        Documents.create_document(%{
          title: "半成品",
          project_id: project.id,
          actor_id: insert(:actor).id,
          markdown: "## 一件活\n"
        })

      assert {:error, :document_not_formal, %{status: :draft}} = Tasks.file_breakdown(draft)
      assert Tasks.list_tasks(project, %{}) == []
    end

    test "relays what the parser refused" do
      breakdown = adopted(insert(:project), "### 无家可归\n\n## 组\n")

      assert {:error, :task_before_chunk, %{}} = Tasks.file_breakdown(breakdown)
    end

    # Either the work exists and the document is spent, or neither happened.
    test "files nothing and spends nothing when one task is refused" do
      project = insert(:project)
      breakdown = adopted(project, "## 组\n\n### #{String.duplicate("长", 300)}\n")

      assert {:error, :validation_error, details} = Tasks.file_breakdown(breakdown)
      assert details["chunk"] == "组"

      assert Tasks.list_tasks(project, %{}) == []
      assert Documents.get_document!(breakdown.id).status == :formal
    end

    # Verbatim from a real run against `docs/document-annotations.md`, quirks
    # and all: escaped underscores in the headings, descriptions that are
    # mostly lists, acceptance written as prose rather than marked up. Hand
    # written Markdown would have tested the parser against my typing.
    test "files what the model actually produced" do
      project = insert(:project)

      breakdown =
        adopted(project, """
        ## 数据模型

        ### 建 annotations 表

        写迁移创建 annotations 表：

        - document_id、actor_id、content 非空
        - status 默认 `open`，取值 `open | resolved | dismissed`

        验收：迁移 up/down 可往返。

        ### 建 annotation_replies 表

        写迁移创建 annotation_replies 表：

        - (annotation_id, position) 唯一约束

        验收：唯一约束生效。

        ## 追评与状态逻辑

        ### 追评 position 分配

        创建追评时，position 取最大 position + 1；删除不重排。
        """)

      assert {:ok, filed} = Tasks.file_breakdown(breakdown)

      assert Enum.map(filed, &{&1.kind, &1.title}) == [
               {:summary, "数据模型"},
               {:work, "建 annotations 表"},
               {:work, "建 annotation_replies 表"},
               {:summary, "追评与状态逻辑"},
               {:work, "追评 position 分配"}
             ]

      # The heading is stored `建 annotation\_replies 表`, and a title column is
      # not Markdown. This is the whole reason titles come off the AST.
      refute Enum.any?(filed, &String.contains?(&1.title, "\\"))

      [_, first, second, _, third] = filed

      # Descriptions keep the escaping, and must: they are Markdown -- the
      # lists in them do not render otherwise -- so `document\_id` is how you
      # write a literal underscore. Stripping it here to match the title would
      # turn somebody's `_x_` into emphasis they never asked for.
      assert first.description =~ "- document\\_id、actor\\_id、content 非空"
      assert first.description =~ "验收：迁移 up/down 可往返。"
      assert second.description =~ "唯一约束生效"
      assert third.description =~ "取最大 position + 1"

      # Chunks carry no description of their own here, because the model wrote
      # none -- it puts the words on the tasks.
      assert Enum.filter(filed, &(&1.kind == :summary)) |> Enum.all?(&(&1.description == nil))
    end
  end

  defp adopted(project, markdown) do
    {:ok, document} =
      Documents.create_document(%{
        title: "任务文档",
        project_id: project.id,
        actor_id: insert(:actor).id,
        markdown: markdown
      })

    {:ok, formal} = Documents.formalize_document(document)
    formal
  end

  defp ids(tasks), do: Enum.map(tasks, & &1.id)

  defp status_of(project, %Task{id: id}) do
    project
    |> Tasks.list_tasks(%{})
    |> Enum.find(&(&1.id == id))
    |> Map.fetch!(:status)
  end
end
