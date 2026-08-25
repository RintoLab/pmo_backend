defmodule RintoPMO.Repo.Migrations.CreateCalendarDays do
  @moduledoc """
  Which days are not what the weekend rule says they are.

  ## Exceptions only

  The default stands on its own: Monday through Friday are worked, 480 minutes
  each. This table holds the days that depart from it, and nothing else, so a
  year with no departures is an empty table rather than 365 rows saying
  "ordinary".

  Three kinds, and they are one question asked three ways -- does this day hold
  480 minutes?

    * `holiday` -- a statutory day off, on a day the weekend rule would have
      worked.
    * `workday` -- the Saturday or Sunday China works to make up for one. The
      same field in the same source produces both, which is why they are one
      table and not two.
    * `leave` -- the person is not there. Sick, away, on holiday of their own.

  The first two are written by the importer and the third by a person, and the
  importer must never touch a `leave` row: they share a table because capacity
  asks them all the same question, not because they share a lifecycle.

  For one person, `leave` is the kind that matters more. A statutory holiday
  arrives a few times a year and is the same for everybody; being away for a
  week is neither, and no announcement covers it. This table would be worth
  having for `leave` alone.

  ## The day is the key

  There is no surrogate id. A date already identifies a row here uniquely, and
  a uuid would only add a column that has to be looked up to answer a question
  the date itself answers.

  ## `calendar_imports` exists to tell two silences apart

  An empty `calendar_days` for 2027 could mean "that year has no exceptions" or
  "nobody has fetched that year yet". Those are opposite facts: the first is
  usable, the second means every capacity figure for 2027 is a guess.

  Without this table the two are indistinguishable and the guess wins silently,
  which is the failure this whole design keeps refusing elsewhere -- a partial
  answer must never pass for a whole one. So a row lands here when a year has
  actually been read, and a week in a year with no row is reported as unknown
  rather than assumed ordinary.

  `updated_at` is when the year was last read. Because the State Council
  amends its announcements, that matters as much as whether it was ever read
  at all: the importer runs daily and this is how you can tell it still is.
  """

  use Ecto.Migration

  def change do
    create table(:calendar_days, primary_key: false) do
      add :day, :date, primary_key: true

      # holiday | workday | leave
      add :kind, :string, null: false

      # What the source called it -- "春节", or whatever a person typed about
      # being away. Shown rather than reasoned about.
      add :name, :string

      timestamps(type: :utc_datetime_usec)
    end

    create constraint(:calendar_days, :calendar_days_kind_check,
             check: "kind IN ('holiday', 'workday', 'leave')"
           )

    # Every read is "the exceptions between these two dates", which is the
    # primary key's own order, so nothing else needs indexing.

    create table(:calendar_imports, primary_key: false) do
      add :year, :integer, primary_key: true

      # Where it was read from, kept so that a row whose numbers look wrong can
      # be traced back to the file that produced them.
      add :source, :string, null: false

      timestamps(type: :utc_datetime_usec)
    end
  end
end
