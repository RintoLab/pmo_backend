defmodule RintoPMO.RequirementPrioritizationTest do
  use RintoPMO.DataCase, async: true
  alias RintoPMO.Agent.RequirementPrioritizerMock
  alias RintoPMO.AIRoles
  alias RintoPMO.Requirements
  alias RintoPMO.Requirements.Prioritization
  alias RintoPMO.Requirements.PrioritizationWorker
  alias RintoPMO.Tasks

  setup do
    project = insert(:project)
    root = insert(:requirement, project: project, description: "Reduce login failures")
    leaf = insert(:requirement, project: project, parent: root)
    {:ok, project: project, root: root, leaf: leaf}
  end

  test "requires configuration, a valid id and an open hierarchy", ctx do
    assert {:error, :no_prioritization_ai, _} = Prioritization.request(ctx.root.id)

    for id <- [nil, [], "bad"] do
      assert {:error, :bad_request, _} = Prioritization.request(id)
    end

    assert {:error, :not_found} = Prioritization.request(Ecto.UUID.generate())
    ctx.project |> change(status: :archived) |> Repo.update!()
    assert {:error, :bad_request, _} = Prioritization.request(ctx.root.id)
  end

  test "deduplicates an in-flight job without expanding to children", ctx do
    job = enqueue(ctx.root.id)
    assert {:ok, %{id: id}} = Prioritization.request(ctx.root.id)
    assert id == job.id
    assert job.args["requirement_id"] == ctx.root.id
    refute Map.has_key?(job.args, "requirement_ids")
  end

  test "directly updates only the chosen requirement and its tasks inherit the result", ctx do
    task = insert(:task, project: ctx.project, requirement: ctx.leaf)
    job = enqueue(ctx.leaf.id)
    document = insert(:document, project: ctx.project, requirement_id: ctx.root.id, kind: :spec)
    insert(:document_revision, document: document, title: "Login requirements")

    expect(RequirementPrioritizerMock, :prioritize, fn input, opts ->
      assert opts[:provider] == "google"
      assert input.id == ctx.leaf.id
      assert input.project.id == ctx.project.id
      assert hd(input.context.requirements).description == "Reduce login failures"
      assert hd(input.context.documents).id == document.id
      {:ok, [%{"requirement_id" => ctx.leaf.id, "priority" => 2}]}
    end)

    assert :ok = PrioritizationWorker.perform(job)
    assert Requirements.get_requirement!(ctx.leaf.id).priority == 2
    assert Tasks.get_task!(task.id).priority == 2
    assert Requirements.get_requirement!(ctx.root.id).priority == 3
    assert Repo.reload!(job).meta == %{}
    assert {:ok, _} = Requirements.update_requirement(ctx.leaf, %{priority: 4})
    assert Tasks.get_task!(task.id).priority == 4
  end

  test "setting a parent's priority leaves children unchanged", ctx do
    job = enqueue(ctx.root.id)

    expect(RequirementPrioritizerMock, :prioritize, fn input, _ ->
      {:ok, [%{"requirement_id" => input.id, "priority" => 1}]}
    end)

    assert :ok = PrioritizationWorker.perform(job)
    assert Requirements.get_requirement!(ctx.root.id).priority == 1
    assert Requirements.get_requirement!(ctx.leaf.id).priority == 3
  end

  test "a manual edit while queued cancels before calling AI", ctx do
    job = enqueue(ctx.leaf.id)
    Requirements.update_requirement(ctx.leaf, %{priority: 4})
    assert {:cancel, _} = PrioritizationWorker.perform(job)
    assert Requirements.get_requirement!(ctx.leaf.id).priority == 4
  end

  test "a manual edit while AI runs takes precedence", ctx do
    job = enqueue(ctx.leaf.id)

    expect(RequirementPrioritizerMock, :prioritize, fn input, _ ->
      Requirements.update_requirement(ctx.leaf, %{priority: 4})
      {:ok, [%{"requirement_id" => input.id, "priority" => 1}]}
    end)

    assert {:cancel, _} = PrioritizationWorker.perform(job)
    assert Requirements.get_requirement!(ctx.leaf.id).priority == 4
  end

  test "changed reference context is not silently used to write a priority", ctx do
    job = enqueue(ctx.leaf.id)

    expect(RequirementPrioritizerMock, :prioritize, fn input, _ ->
      Requirements.update_requirement(ctx.root, %{description: "Changed scope"})
      {:ok, [%{"requirement_id" => input.id, "priority" => 1}]}
    end)

    assert {:cancel, _} = PrioritizationWorker.perform(job)
    assert Requirements.get_requirement!(ctx.leaf.id).priority == 3
  end

  test "closed scope at worker time cancels without calling the model", ctx do
    job = enqueue(ctx.leaf.id)
    ctx.root |> change(status: :completed) |> Repo.update!()
    assert {:cancel, _} = PrioritizationWorker.perform(job)
  end

  test "rejects invalid, missing, multiple and wrong-target model results without writes", ctx do
    job = enqueue(ctx.root.id)
    valid = %{"requirement_id" => ctx.root.id, "priority" => 2}

    for result <- [
          [],
          [valid, valid],
          [%{valid | "requirement_id" => ctx.leaf.id}],
          [%{valid | "priority" => 0}],
          [%{valid | "priority" => 6}],
          [%{valid | "priority" => 2.0}],
          [%{}]
        ] do
      expect(RequirementPrioritizerMock, :prioritize, fn _, _ -> {:ok, result} end)
      assert {:cancel, _} = PrioritizationWorker.perform(job)
      assert Requirements.get_requirement!(ctx.root.id).priority == 3
    end

    expect(RequirementPrioritizerMock, :prioritize, fn _, _ -> {:error, :timeout} end)
    assert {:cancel, _} = PrioritizationWorker.perform(job)
    assert Requirements.get_requirement!(ctx.root.id).priority == 3
  end

  test "enforces context size before invoking a model", ctx do
    ctx.root |> change(description: String.duplicate("x", 210_000)) |> Repo.update!()
    assert {:cancel, reason} = PrioritizationWorker.perform(enqueue(ctx.root.id))
    assert reason =~ "200 KB"
  end

  defp enqueue(id) do
    AIRoles.put_role("requirement_prioritization", %{
      "provider" => "google",
      "model" => "flash",
      "thinking_level" => "off"
    })

    {:ok, job} = Prioritization.request(id)
    Repo.get!(Oban.Job, job.id)
  end
end
