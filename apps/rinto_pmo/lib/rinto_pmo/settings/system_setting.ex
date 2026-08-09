defmodule RintoPMO.Settings.SystemSetting do
  @moduledoc """
  One system-wide role, and the actor currently playing it.

  A row is a pointer, not a value: `key` names a job the system needs somebody
  to do and `actor_id` says who does it. `RintoPMO.Settings` lists the jobs
  that exist.
  """

  use RintoPMO, :schema

  alias RintoPMO.Actors.Actor

  @type t :: %__MODULE__{}

  schema "system_settings" do
    field :key, :string

    belongs_to :actor, Actor

    timestamps()
  end

  @doc false
  def changeset(%__MODULE__{} = setting \\ %__MODULE__{}, attrs) do
    setting
    |> cast(attrs, [:key, :actor_id])
    |> validate_required([:key])
    |> unique_constraint(:key)
    |> foreign_key_constraint(:actor_id)
  end
end
