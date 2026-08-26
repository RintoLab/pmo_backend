defmodule RintoPMO.CalibrationTest do
  use RintoPMO.DataCase, async: true

  alias RintoPMO.Calibration

  defp at(%Date{} = day), do: DateTime.new!(day, ~T[17:00:00.000000])

  # Finished, with whichever of the three numbers a test cares about.
  defp finished(attrs) do
    insert(:task, Keyword.merge([status: :done, completed_at: at(~D[2026-06-10])], attrs))
  end

  defp estimated(minutes) do
    [estimate_optimistic: minutes, estimate_likely: minutes, estimate_pessimistic: minutes]
  end

  describe "weeks/3" do
    test "groups by the week work was finished in, and keeps the empty weeks" do
      finished(completed_at: at(~D[2026-06-09]))
      finished(completed_at: at(~D[2026-06-11]))
      finished(completed_at: at(~D[2026-06-23]))

      assert [
               %{week: ~D[2026-06-08], completed: 2},
               %{week: ~D[2026-06-15], completed: 0},
               %{week: ~D[2026-06-22], completed: 1}
             ] = Calibration.weeks(~D[2026-06-08], ~D[2026-06-28])
    end

    # Two totals over two different populations have a meaningless ratio, so
    # only the tasks carrying both numbers are summed -- and the ones left out
    # are counted, or a reader cannot tell a signal from a coincidence.
    test "sums only what can be compared, and says what was left out" do
      finished(estimated(120) ++ [actual_minutes: 180])
      finished(estimated(60) ++ [actual_minutes: 60])
      finished(estimated(240) ++ [actual_minutes: nil])
      finished(actual_minutes: 999)

      assert [week] = Calibration.weeks(~D[2026-06-08], ~D[2026-06-14])

      assert week.completed == 4
      assert week.comparable == 2
      assert week.expected_minutes == 180
      assert week.actual_minutes == 240
      assert week.unestimated == 1
      assert week.unmeasured == 1
    end

    # Cancelled work has no `completed_at` by design, and time spent on
    # something that was dropped is not what a finished estimate cost.
    test "counts only work that was actually delivered" do
      finished(estimated(60) ++ [actual_minutes: 60])
      insert(:task, status: :cancelled, started_at: at(~D[2026-06-09]), actual_minutes: 300)
      insert(:task, status: :in_progress, started_at: at(~D[2026-06-09]))

      assert [%{completed: 1, actual_minutes: 60}] =
               Calibration.weeks(~D[2026-06-08], ~D[2026-06-14])
    end

    # A cover's estimate and actual are sums over its children, so counting it
    # too would count the same work twice.
    test "a cover is never counted beside its children" do
      project = insert(:project)
      cover = insert(:task, project: project, kind: :summary)

      finished([project: project, parent: cover, actual_minutes: 90] ++ estimated(60))

      assert [%{completed: 1, comparable: 1, actual_minutes: 90}] =
               Calibration.weeks(~D[2026-06-08], ~D[2026-06-14])
    end

    test "narrows to one project when asked" do
      mine = insert(:project)
      finished([project: mine, actual_minutes: 60] ++ estimated(60))
      finished([project: insert(:project), actual_minutes: 999] ++ estimated(480))

      assert [%{completed: 1, actual_minutes: 60}] =
               Calibration.weeks(~D[2026-06-08], ~D[2026-06-14], mine.id)
    end
  end

  describe "by_difficulty/3" do
    test "answers every rung, including the ones nothing reached" do
      assert Calibration.by_difficulty(~D[2026-06-08], ~D[2026-06-14])
             |> Enum.map(& &1.difficulty) == [1, 2, 3, 5, 8, 13, 21]

      assert Enum.all?(
               Calibration.by_difficulty(~D[2026-06-08], ~D[2026-06-14]),
               &(&1.tasks == 0 and is_nil(&1.median_actual_minutes))
             )
    end

    # The middle value, not the average: one task that ran three days would
    # move a mean somewhere no task ever was, and it would read as knowledge.
    test "reports the middle duration at each rung" do
      for minutes <- [60, 90, 600], do: finished(difficulty: 5, actual_minutes: minutes)
      finished(difficulty: 5, actual_minutes: nil)
      finished(difficulty: 2, actual_minutes: 30)

      rungs =
        ~D[2026-06-08]
        |> Calibration.by_difficulty(~D[2026-06-14])
        |> Map.new(&{&1.difficulty, &1})

      assert rungs[5].tasks == 4
      assert rungs[5].measured == 3
      assert rungs[5].median_actual_minutes == 90
      assert rungs[2].median_actual_minutes == 30
      assert rungs[8].tasks == 0
    end

    test "averages the middle pair when there is an even number of them" do
      for minutes <- [60, 100], do: finished(difficulty: 3, actual_minutes: minutes)

      rungs =
        ~D[2026-06-08]
        |> Calibration.by_difficulty(~D[2026-06-14])
        |> Map.new(&{&1.difficulty, &1})

      assert rungs[3].median_actual_minutes == 80
    end

    test "ignores work finished outside the window" do
      finished(difficulty: 5, actual_minutes: 60, completed_at: at(~D[2026-05-01]))

      rungs =
        ~D[2026-06-08]
        |> Calibration.by_difficulty(~D[2026-06-14])
        |> Map.new(&{&1.difficulty, &1})

      assert rungs[5].tasks == 0
    end
  end
end
