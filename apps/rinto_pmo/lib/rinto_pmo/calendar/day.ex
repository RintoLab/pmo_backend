defmodule RintoPMO.Calendar.Day do
  @moduledoc """
  One day the weekend rule gets wrong, as the State Council announced it.

  Two kinds, and the same field in the same source produces both: a `holiday`
  is a statutory day off on a day that would have been worked, and a `workday`
  is the Saturday or Sunday worked to make up for one. See the
  `20260824110000_create_calendar_days` migration for why the date is the key.

  Every row here comes from an import, and an import may delete every row here
  for the year it is rewriting. Being away is not one of these -- it is
  `RintoPMO.Calendar.Leave`, in a table an import cannot reach, which is what
  keeps a person's time off out of a delete-and-rewrite that has nothing to do
  with it.
  """

  use RintoPMO, :schema

  @type t :: %__MODULE__{}
  @type kind :: :holiday | :workday

  @kinds [:holiday, :workday]

  @primary_key {:day, :date, autogenerate: false}
  schema "calendar_days" do
    field :kind, Ecto.Enum, values: @kinds
    field :name, :string

    timestamps()
  end

  @doc """
  The kinds a calendar day can be.
  """
  @spec kinds() :: [kind()]
  def kinds, do: @kinds

  @doc false
  def changeset(%__MODULE__{} = day \\ %__MODULE__{}, attrs) do
    day
    |> cast(attrs, [:day, :kind, :name])
    |> validate_required([:day, :kind])
    |> check_constraint(:kind, name: :calendar_days_kind_check, message: "is invalid")
  end
end
