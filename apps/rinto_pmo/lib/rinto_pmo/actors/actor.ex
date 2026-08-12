defmodule RintoPMO.Actors.Actor do
  @moduledoc """
  A human or AI participant.

  Actors provide attribution and AI persona configuration.

  ## The one authentication field

  `token` is the exception, and is deliberately the whole of it: this system
  assumes a single person operating it, so "who is calling" has exactly one
  answer and needs no account, password or session behind it. A token is a
  human's, never an AI's -- an AI actor is named by whoever is already holding
  one, and makes no requests of its own.

  There is still no authorization here. A valid token identifies the person; it
  does not say what they may do, because there is nobody to distinguish them
  from.

  `token` is set programmatically by `RintoPMO.Actors` and is not castable, so
  no request body can write one.
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
    field :token, :string

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

  @doc """
  Puts `token` on a human actor, or takes it away with `nil`.

  Separate from `changeset/2` rather than another castable field: a token is
  the one thing here that decides whether a request is answered at all, and it
  must not be reachable from the same body that edits a name.
  """
  @spec token_changeset(t(), String.t() | nil) :: Ecto.Changeset.t()
  def token_changeset(%__MODULE__{} = actor, token) when is_binary(token) or is_nil(token) do
    actor
    |> change(token: token)
    |> validate_human()
    |> unique_constraint(:token)
    |> check_constraint(:token, name: :actors_token_human_only, message: "belongs to a human")
  end

  # Clearing is allowed whatever the kind -- "this actor has no token" is true
  # of every AI already, and refusing to write down something that is the case
  # would only make the caller special-case it.
  defp validate_human(chset) do
    case {fetch_field!(chset, :token), fetch_field!(chset, :kind)} do
      {nil, _kind} -> chset
      {_token, :human} -> chset
      {_token, _ai} -> add_error(chset, :token, "belongs to a human")
    end
  end
end
