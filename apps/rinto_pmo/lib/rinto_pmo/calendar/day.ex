defmodule RintoPMO.Calendar.Day do
  @moduledoc """
  One day that is not what the weekend rule says it is.

  See the `20260824110000_create_calendar_days` migration for why the three
  kinds share a table and why the date is the key.

  `kind` is not settable in one changeset for all three. `imported_changeset/1`
  writes the two that come from the State Council and `leave_changeset/2`
  writes the one that comes from a person, so that no path exists by which an
  import could produce a `leave` row or a person could hand-write a holiday
  that the next import would silently revoke.
  """

  use RintoPMO, :schema

  @type t :: %__MODULE__{}
  @type kind :: :holiday | :workday | :leave

  @kinds [:holiday, :workday, :leave]

  # The kinds an import owns. Everything the importer deletes and rewrites is
  # bounded by this list, which is what keeps `leave` out of its reach.
  @imported_kinds [:holiday, :workday]

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

  @doc """
  The kinds that come from an import, and that an import may delete.
  """
  @spec imported_kinds() :: [kind()]
  def imported_kinds, do: @imported_kinds

  @doc false
  def imported_changeset(attrs) do
    %__MODULE__{}
    |> cast(attrs, [:day, :kind, :name])
    |> validate_required([:day, :kind])
    |> validate_inclusion(:kind, @imported_kinds)
    |> check_constraint(:kind, name: :calendar_days_kind_check, message: "is invalid")
  end

  @doc false
  def leave_changeset(%__MODULE__{} = day \\ %__MODULE__{}, attrs) do
    day
    |> cast(attrs, [:day, :name])
    |> put_change(:kind, :leave)
    |> validate_required([:day])
  end
end
