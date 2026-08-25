defmodule RintoPMO.Tasks.DependencyGraphTest do
  # Not async: every test here writes the process-global table directly, rather
  # than through tasks whose ids keep them apart.
  use RintoPMO.DataCase, async: false

  alias RintoPMO.Tasks
  alias RintoPMO.Tasks.DependencyGraph

  setup do
    on_exit(&DependencyGraph.reload/0)

    :ok = DependencyGraph.reload()
    %{project: insert(:project)}
  end

  defp ids(n), do: Enum.map(1..n, fn _ -> UUIDv7.generate() end)

  describe "path/2" do
    test "finds nothing in an empty table" do
      [a, b] = ids(2)

      assert DependencyGraph.path(a, b) == nil
    end

    test "finds a direct edge" do
      [a, b] = ids(2)
      # b waits for a.
      :ok = DependencyGraph.put(b, a)

      assert DependencyGraph.path(a, b) == [a, b]
    end

    test "returns the whole chain, in order" do
      [a, b, c, d] = ids(4)
      :ok = DependencyGraph.put(b, a)
      :ok = DependencyGraph.put(c, b)
      :ok = DependencyGraph.put(d, c)

      assert DependencyGraph.path(a, d) == [a, b, c, d]
    end

    test "does not walk backwards along an edge" do
      [a, b] = ids(2)
      :ok = DependencyGraph.put(b, a)

      assert DependencyGraph.path(b, a) == nil
    end

    test "terminates on a table that somehow contains a loop" do
      [a, b] = ids(2)
      :ok = DependencyGraph.put(b, a)
      :ok = DependencyGraph.put(a, b)

      # The question still gets an answer instead of spinning.
      assert DependencyGraph.path(a, b) == [a, b]
      assert DependencyGraph.path(a, UUIDv7.generate()) == nil
    end
  end

  describe "forgetting" do
    test "drop/2 removes one edge and leaves the rest" do
      [a, b, c] = ids(3)
      :ok = DependencyGraph.put(b, a)
      :ok = DependencyGraph.put(c, b)

      :ok = DependencyGraph.drop(b, a)

      assert DependencyGraph.path(a, b) == nil
      assert DependencyGraph.path(b, c) == [b, c]
    end

    test "forget_task/1 removes edges at both ends" do
      [a, b, c] = ids(3)
      :ok = DependencyGraph.put(b, a)
      :ok = DependencyGraph.put(c, b)

      :ok = DependencyGraph.forget_task(b)

      assert DependencyGraph.path(a, b) == nil
      assert DependencyGraph.path(b, c) == nil
    end
  end

  describe "staleness errs on the safe side" do
    test "an edge the database no longer has refuses rather than permits", %{project: project} do
      one = insert(:task, project: project)
      two = insert(:task, project: project)

      # Exactly the shape a cascade leaves behind: the cache believes `two`
      # waits for `one`, and the database has no such row.
      :ok = DependencyGraph.put(two.id, one.id)

      # So making `one` wait for `two` is refused. Over-cautious, and the
      # opposite mistake -- permitting a real loop -- is the one that cannot
      # happen from stale data.
      assert {:error, :dependency_cycle, %{cycle: cycle}} =
               Tasks.add_dependency(one, two.id)

      assert cycle == [one.id, two.id]
    end

    test "a missing edge is what a write path must never produce", %{project: project} do
      waiting = insert(:task, project: project)
      prerequisite = insert(:task, project: project)

      {:ok, _} = Tasks.add_dependency(waiting, prerequisite.id)

      # Written to the cache by `add_dependency/2` itself, in the same process
      # as the insert, so there is no window in which the row exists and this
      # does not.
      assert DependencyGraph.path(prerequisite.id, waiting.id) == [prerequisite.id, waiting.id]
    end
  end

  describe "reload/0" do
    test "clears what is no longer backed by a row" do
      [a, b] = ids(2)
      :ok = DependencyGraph.put(b, a)

      :ok = DependencyGraph.reload()

      assert DependencyGraph.path(a, b) == nil
    end
  end
end
