defmodule RintoPMO.Repo.Migrations.RecordWhenATaskWasFirstPlanned do
  @moduledoc """
  One column, so that "this slipped" survives the act of rescheduling.

  `planned_start_on` is the current plan, and moving it is the ordinary way to
  replan. That makes it useless as a baseline: a task pushed from week 1 to
  week 6 reads as though it were always meant for week 6, and the slip -- the
  most informative thing about it -- is gone the moment somebody acts on it.

  So `first_planned_on` records the day it was *first* selected into any week,
  and never moves again. Returning a task to the backlog and planning it afresh
  does not reset it either: the question it answers is "when did we first say
  we would do this", and the answer does not change by our saying it again.

  Never written by a client. It is set by the changeset the first time
  `planned_start_on` goes from null to a day, which is the only moment it can
  be known.

  A cover holds none, like everything else that lays claim to somebody's time,
  so it joins `tasks_summary_holds_no_work_check`.

  ## The backfill is the honest one

  Existing rows take their current `planned_start_on` as their baseline. That
  understates the slip of anything already rescheduled -- but the earlier value
  was never recorded, and inventing one would put a number on a measurement
  nobody made. Rows in the backlog stay null and get a baseline when they are
  first planned, like anything created after this.
  """

  use Ecto.Migration

  def up do
    alter table(:tasks) do
      add :first_planned_on, :date
    end

    execute "UPDATE tasks SET first_planned_on = planned_start_on WHERE planned_start_on IS NOT NULL"

    drop constraint(:tasks, :tasks_summary_holds_no_work_check)

    create constraint(:tasks, :tasks_summary_holds_no_work_check,
             check: """
             kind <> 'summary' OR (
               assignee_id IS NULL AND assigned_at IS NULL
               AND started_at IS NULL AND completed_at IS NULL
               AND estimate_optimistic IS NULL AND estimate_likely IS NULL
               AND estimate_pessimistic IS NULL
               AND difficulty IS NULL AND actual_minutes IS NULL
               AND planned_start_on IS NULL AND first_planned_on IS NULL
             )
             """
           )

    # What the record view reads: work that was actually started, newest first
    # within a window. Partial, because a task nobody began has nothing to
    # report and the backlog is the pile that grows without bound.
    create index(:tasks, [:started_at],
             where: "started_at IS NOT NULL",
             name: :tasks_started_index
           )
  end

  def down do
    drop index(:tasks, [:started_at], name: :tasks_started_index)
    drop constraint(:tasks, :tasks_summary_holds_no_work_check)

    create constraint(:tasks, :tasks_summary_holds_no_work_check,
             check: """
             kind <> 'summary' OR (
               assignee_id IS NULL AND assigned_at IS NULL
               AND started_at IS NULL AND completed_at IS NULL
               AND estimate_optimistic IS NULL AND estimate_likely IS NULL
               AND estimate_pessimistic IS NULL
               AND difficulty IS NULL AND actual_minutes IS NULL
               AND planned_start_on IS NULL
             )
             """
           )

    alter table(:tasks) do
      remove :first_planned_on
    end
  end
end
