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

  ## One row is the AI nobody named

  A plain-chat topic talks to a provider and a model the person picked, not to
  a persona -- so when an AI writes into a document from one, there is no actor
  standing there to credit. `default` marks the row that stands in: an ordinary
  AI actor except that it carries no model configuration, because its model is
  whatever the topic was using. It answers "a model wrote this, not a person",
  which is the distinction the review flow rests on, and nothing more.

  At most one row has it, and it is set at setup rather than cast from a
  caller: see `RintoPMO.Setup.ensure_default_assistant/0`. Nothing runs on it
  -- anything that needs a model to call refuses it, because it has none.
  """

  use RintoPMO, :schema

  @type t :: %__MODULE__{}

  schema "actors" do
    field :kind, Ecto.Enum, values: [:human, :ai]
    field :name, :string
    field :description, :string
    field :enabled, :boolean, default: true
    field :default, :boolean, default: false
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

      # Renaming the stand-in, or turning it off, is ordinary. Giving it a model
      # is not: `default` is never cast here, so a caller cannot make one, and
      # requiring a model of the one that exists would make it uneditable.
      fetch_field!(chset, :default) ->
        chset

      true ->
        cast_ai_configuration(chset, attrs)
    end
  end

  @doc """
  The stand-in for an AI nobody named. Not reachable from the API.

  Written only by `RintoPMO.Setup`, which is why `default` is set here rather
  than cast: an actor a caller could mark would be a second one, and which of
  the two signs a block is not a question this system wants to have.
  """
  def default_changeset(attrs) do
    %__MODULE__{}
    |> cast(attrs, [:name, :description])
    |> validate_required([:name])
    |> put_change(:kind, :ai)
    |> put_change(:default, true)
    |> unique_constraint(:default, name: :actors_one_default)
    |> check_constraint(:default, name: :actors_default_has_no_model)
  end

  defp cast_ai_configuration(chset, attrs) do
    chset
    |> cast(attrs, [:provider, :model, :thinking_level, :system_prompt, :injection_profile])
    |> validate_required([:provider, :model, :thinking_level])
  end
end
