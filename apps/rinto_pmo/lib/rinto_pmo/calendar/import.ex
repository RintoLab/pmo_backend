defmodule RintoPMO.Calendar.Import do
  @moduledoc """
  A record that some year's calendar has actually been read.

  It exists so that "no exceptions" and "never fetched" are different answers.
  Without it an empty `calendar_days` for a year would read as an ordinary
  year, and every capacity figure in it would be a guess wearing the clothes
  of a fact.

  `updated_at` is when the year was last read, which is the more useful half:
  the State Council amends its announcements, so a year read once in January is
  not the same as a year read this morning.
  """

  use RintoPMO, :schema

  @type t :: %__MODULE__{}

  @primary_key {:year, :integer, autogenerate: false}
  schema "calendar_imports" do
    field :source, :string

    timestamps()
  end

  @doc false
  def changeset(%__MODULE__{} = import \\ %__MODULE__{}, attrs) do
    import
    |> cast(attrs, [:year, :source])
    |> validate_required([:year, :source])
  end
end
