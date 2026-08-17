defmodule RintoPMO.Actors.Actor do
  @moduledoc """
  A human or AI participant.

  Actors provide attribution and AI persona configuration.

  ## No credential lives here

  There is deliberately no token field. The token this system authenticates
  with is agreed in advance and configured on the server, not issued to a row
  and handed out (see `RintoPMO.Actors`), so an actor is a record of who
  somebody is and never of how they prove it. Nothing here is a secret, which
  is what makes `GET /actors` renderable to anybody at all.

  There is no authorization either. Authentication identifies the person; it
  does not say what they may do, because there is nobody to distinguish them
  from.
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
    field :thinking_level, :string
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
