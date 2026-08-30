defmodule RintoPMO.Calendar.Leave do
  @moduledoc """
  How many minutes of one day a person is not there.

  A table of its own rather than a third `kind` in `RintoPMO.Calendar.Day`, for
  the reason the `20260830100000_leave_is_measured_in_minutes` migration gives:
  a holiday *assigns* a day's minutes and leave *subtracts* from them, and while
  leave could only ever mean "all of them" the difference did not show.

  `minutes` has no upper bound. Whether a number is the whole day is a
  comparison against whatever that day holds -- `RintoPMO.Calendar.capacity_on/2`
  makes it, every time it is asked -- not a fact about the row. A ceiling here
  would write today's `daily_capacity/0` into rows that outlive it.

  The convention for a whole day off is 1440, every minute of a calendar day.
  Nothing enforces it and nothing needs to: it is a physical constant, so it
  exceeds any capacity a day could be given later, which is exactly the property
  480 would not have.
  """

  use RintoPMO, :schema

  @type t :: %__MODULE__{}

  @primary_key {:day, :date, autogenerate: false}
  schema "calendar_leaves" do
    field :minutes, :integer
    field :name, :string

    timestamps()
  end

  @doc false
  def changeset(%__MODULE__{} = leave \\ %__MODULE__{}, attrs) do
    leave
    |> cast(attrs, [:day, :minutes, :name])
    |> validate_required([:day, :minutes])
    |> validate_number(:minutes, greater_than: 0)
    |> check_constraint(:minutes,
      name: :calendar_leaves_minutes_positive,
      message: "must be greater than 0"
    )
  end
end
