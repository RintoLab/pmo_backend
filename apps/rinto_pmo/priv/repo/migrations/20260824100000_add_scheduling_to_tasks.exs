defmodule RintoPMO.Repo.Migrations.AddSchedulingToTasks do
  @moduledoc """
  Two columns that let a week be filled instead of merely counted.

  ## `planned_start_on` is "not before this day", and it is also the act

  It is not "the day this starts" -- where a task actually lands is computed by
  `RintoPMO.Schedule`, which fills each workday's 480 minutes in order. This
  column says the earliest day the task may be considered.

  It is at the same time the whole of "put this task into that iteration":
  setting it to a day in some week selects the task into that week; leaving it
  null means the task is never a candidate for any week. That null *is* the
  backlog -- there is no `:backlog` status, because "which slot of the plan"
  is a many-valued question and a status enum can only hold two of its answers.

  An iteration is a week. It is not stored anywhere: it is an argument to the
  packing function, not a row. Nothing here carries a `project_id` either,
  because one person's week spans every project they work on.

  A cover holds no schedule, for the same reason it holds no assignee: an
  iteration is a claim on somebody's time, and a cover has no somebody. So the
  column joins the rest of the work columns in
  `tasks_summary_holds_no_work_check`.

  ## `priority` is five levels, and not null

  1 is highest, 3 is the default. Not null, because "no opinion" *is* "normal"
  -- unlike an estimate, whose absence is a fact worth reporting (see
  `unestimated_tasks`), a missing priority carries no information and would
  only invite a counter that nobody would read.

  It decides who gets cut when a week is over-filled, so it sorts ahead of
  everything else, including how long a task has been waiting: work carried
  over from last week has no claim to jump the queue.

  ## The estimate now has a ceiling of 480 minutes

  One working day. This is what makes the filling model work rather than an
  arbitrary limit: no work item can be larger than a day, so no work item can
  be permanently unschedulable for being too big. A task still spans days --
  but only from packing pressure (Monday has 200 minutes left, a 300-minute
  task takes 200 of it and 100 of Tuesday), never because the task itself
  outgrew a day.

  A work item longer than a day is one that was not broken down far enough,
  and this repository already has the answer to that: split it.

  Only `estimate_pessimistic` is checked, because `tasks_estimate_ordered_check`
  already guarantees `optimistic <= likely <= pessimistic`. Capping all three
  would restate that constraint rather than add to it.
  """

  use Ecto.Migration

  @ceiling 480

  def up do
    alter table(:tasks) do
      add :planned_start_on, :date
      add :priority, :integer, null: false, default: 3
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
               AND planned_start_on IS NULL
             )
             """
           )

    create constraint(:tasks, :tasks_priority_check, check: "priority >= 1 AND priority <= 5")

    create constraint(:tasks, :tasks_estimate_ceiling_check,
             check: "estimate_pessimistic IS NULL OR estimate_pessimistic <= #{@ceiling}"
           )

    # What `RintoPMO.Schedule` reads: real work, still unfinished, selected into
    # some week. A partial index keeps it off the backlog and off everything
    # already behind us -- the two piles that grow without bound.
    create index(:tasks, [:planned_start_on],
             where: """
             kind = 'work' AND planned_start_on IS NOT NULL
             AND status IN ('open', 'in_progress')
             """,
             name: :tasks_scheduled_index
           )
  end

  def down do
    drop index(:tasks, [:planned_start_on], name: :tasks_scheduled_index)
    drop constraint(:tasks, :tasks_estimate_ceiling_check)
    drop constraint(:tasks, :tasks_priority_check)
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

    alter table(:tasks) do
      remove :priority
      remove :planned_start_on
    end
  end
end
