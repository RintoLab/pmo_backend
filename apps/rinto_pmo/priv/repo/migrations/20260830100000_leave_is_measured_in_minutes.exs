defmodule RintoPMO.Repo.Migrations.LeaveIsMeasuredInMinutes do
  @moduledoc """
  Being away for two hours is not the same as being away all day.

  `leave` was a third `kind` in `calendar_days`, and the
  `20260824110000_create_calendar_days` migration gave the reason: all three
  kinds answered one question -- does this day hold 480 minutes? That premise
  is what changes here. A base calendar says how many minutes a day *starts*
  with; leave takes some of them away. Subtraction and assignment are not the
  same operation, and a column that has to be both is neither.

  So the kinds split by who writes them, which is what they were all along:
  `calendar_days` keeps `holiday` and `workday`, both from the State Council,
  and `calendar_leaves` gets a table of its own.

  ## The single table was already losing data

  Not a future problem -- a present one, in two places, both silent:

    * `put_leave/2` wrote `on_conflict: {:replace, [:kind, :name, :updated_at]}`
      keyed on the date. Taking a day off on a make-up Saturday overwrote the
      `workday` row, and there was nothing left to say the day had ever been
      one.

    * `import_year/3` deleted the year's `holiday` and `workday` rows and
      re-inserted with `on_conflict: :nothing`. A date already holding a
      `leave` row therefore *rejected its own holiday*, quietly. "The importer
      never overwrites your leave" was true, but it was implemented by letting
      the import fail on that date, so deleting the leave afterwards left the
      day reading as an ordinary 480-minute Wednesday.

  Two tables end both. Nothing in `calendar_days` collides with a leave, and
  `import_year/3` can go back to writing its rows plainly -- an insert that
  conflicts now means the source handed us the same date twice, which should
  abort the year rather than be skipped.

  ## Minutes, with no ceiling

  `minutes` is a positive integer and nothing more. There is no upper bound and
  no `all_day` flag, because "is this the whole day" is a *comparison*, not a
  property of the record: `max(base_capacity - minutes, 0)`, evaluated against
  whatever a day holds at the time it is asked.

  Validating against 480 on the way in would freeze today's daily capacity into
  rows that outlive it. Storing the number a person actually gave keeps the
  judgement where it can still be made correctly: 600 minutes recorded now
  zeroes a 480-minute day, and would leave 120 of a 720-minute one.

  By convention a whole day off is **1440** -- every minute of a calendar day.
  It is a physical constant rather than a copy of `daily_capacity/0`, so it
  reads as a whole day under any capacity the future picks. That is the number
  the existing `leave` rows are backfilled with: each of them meant all day,
  because all day was the only thing they could mean.
  """

  use Ecto.Migration

  def up do
    create table(:calendar_leaves, primary_key: false) do
      add :day, :date, primary_key: true

      # How much of the day is gone. Not capped: see the moduledoc.
      add :minutes, :integer, null: false

      # What the person called it -- "看医生". Shown, never reasoned about.
      add :name, :string

      timestamps(type: :utc_datetime_usec)
    end

    create constraint(:calendar_leaves, :calendar_leaves_minutes_positive, check: "minutes > 0")

    flush()

    execute """
    INSERT INTO calendar_leaves (day, minutes, name, inserted_at, updated_at)
    SELECT day, 1440, name, inserted_at, updated_at
      FROM calendar_days
     WHERE kind = 'leave'
    """

    execute "DELETE FROM calendar_days WHERE kind = 'leave'"

    drop constraint(:calendar_days, :calendar_days_kind_check)

    create constraint(:calendar_days, :calendar_days_kind_check,
             check: "kind IN ('holiday', 'workday')"
           )
  end

  def down do
    drop constraint(:calendar_days, :calendar_days_kind_check)

    create constraint(:calendar_days, :calendar_days_kind_check,
             check: "kind IN ('holiday', 'workday', 'leave')"
           )

    flush()

    # Partial leave has no representation on the way back: a row in the old
    # table is the whole day or it is not there. Two hours off returns as a day
    # off, which overstates it -- and clobbers the base kind on that date the
    # same way the old write did, because that is the shape being restored.
    execute """
    INSERT INTO calendar_days (day, kind, name, inserted_at, updated_at)
    SELECT day, 'leave', name, inserted_at, updated_at
      FROM calendar_leaves
        ON CONFLICT (day)
        DO UPDATE SET kind = 'leave', name = EXCLUDED.name, updated_at = EXCLUDED.updated_at
    """

    drop table(:calendar_leaves)
  end
end
