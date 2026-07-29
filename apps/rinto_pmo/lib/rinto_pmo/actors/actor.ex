defmodule RintoPMO.Actors.Actor do
  @moduledoc """
  A human or AI participant.

  Actors provide attribution and AI persona configuration. They deliberately
  contain no authentication or authorization fields.
  """

  use RintoPMO, :schema

  @type t :: %__MODULE__{}

  schema "actors" do
    field :kind, Ecto.Enum, values: [:human, :ai]
    field :name, :string
    field :description, :string
    field :enabled, :boolean, default: true
    field :provider, :string
    field :model, :string
    field :thinking_level, Ecto.Enum, values: [:off, :low, :medium, :high, :max]
    field :system_prompt, :string
    field :injection_profile, :map

    timestamps()
  end

  @doc false
  def changeset(%__MODULE__{} = actor \\ %__MODULE__{}, attrs) do
    chset =
      actor
      |> cast(attrs, [:kind, :name, :description, :enabled])
      |> validate_required([:kind, :name, :enabled])

    cond do
      chset.valid? == false ->
        chset

      actor.kind && changed?(chset, :kind) ->
        add_error(chset, :kind, "cannot change kind of actor")

      fetch_field!(chset, :kind) == :human ->
        chset

      true ->
        cast_ai_configuration(chset, attrs)
    end
  end

  defp cast_ai_configuration(chset, attrs) do
    chset
    |> cast(attrs, [:provider, :model, :thinking_level, :system_prompt, :injection_profile])
    |> validate_required([:provider, :model, :thinking_level])
  end
end
