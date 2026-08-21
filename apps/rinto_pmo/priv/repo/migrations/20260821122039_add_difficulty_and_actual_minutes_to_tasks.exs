defmodule RintoPMO.Repo.Migrations.AddDifficultyAndActualMinutesToTasks do
  @moduledoc """
  A work item now carries two more measurements, both in the same spirit as
  the three-point estimate: stored only on `:work` rows, empty on a cover.

  `difficulty` is a Fibonacci story point -- 1, 2, 3, 5, 8, 13, 21. It is a
  rating of the work, not a duration. Duration is the estimate; this is the
  knob that later estimates are calibrated against. 21 is the ceiling rather
  than a rung on the way up: it is the rating that says the work should
  probably be split, and inventing a bigger number would say less.

  `actual_minutes` is how long the work took, recorded rather than derived.
  `started_at` to `completed_at` is wall time and counts the night, which is
  useless as a calibration sample. Minutes, like the estimate, so a breakdown
  can sum them exactly.
  """

  use Ecto.Migration

  def up do
    alter table(:tasks) do
      add :difficulty, :integer
      add :actual_minutes, :integer
    end

    drop constraint(:tasks, :tasks_summary_holds_no_work_check)

    create constraint(:tasks, :tasks_summary_holds_no_work_check,
             check: """
             kind <> 'summary' OR (
               assignee_id IS NULL AND assigned_at IS NULL
               AND started_at IS NULL AND completed_at IS NULL
               AND estimate_optimistic IS NULL AND estimate_likely IS NULL
               AND estimate_pessimistic IS NULL
               AND difficulty IS NULL AND actual_minutes IS NULL
             )
             """
           )

    create constraint(:tasks, :tasks_difficulty_check,
             check: "difficulty IS NULL OR difficulty IN (1, 2, 3, 5, 8, 13, 21)"
           )

    create constraint(:tasks, :tasks_actual_minutes_check,
             check: "actual_minutes IS NULL OR actual_minutes >= 0"
           )
  end

  def down do
    drop constraint(:tasks, :tasks_actual_minutes_check)
    drop constraint(:tasks, :tasks_difficulty_check)
    drop constraint(:tasks, :tasks_summary_holds_no_work_check)

    create constraint(:tasks, :tasks_summary_holds_no_work_check,
             check: """
             kind <> 'summary' OR (
               assignee_id IS NULL AND assigned_at IS NULL
               AND started_at IS NULL AND completed_at IS NULL
               AND estimate_optimistic IS NULL AND estimate_likely IS NULL
               AND estimate_pessimistic IS NULL
             )
             """
           )

    alter table(:tasks) do
      remove :actual_minutes
      remove :difficulty
    end
  end
end
