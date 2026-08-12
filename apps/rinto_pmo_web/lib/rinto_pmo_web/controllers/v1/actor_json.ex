defmodule RintoPMOWeb.V1.ActorJSON do
  alias RintoPMO.Actors.Actor

  def index(%{actors: actors}) do
    %{data: Enum.map(actors, &data/1)}
  end

  def show(%{actor: actor}) do
    %{data: data(actor)}
  end

  @doc """
  The token, on its own, for the one response that is allowed to carry it.

  Deliberately not part of `data/1`: `GET /actors` renders every actor to
  anybody holding a token, and an actor payload that sometimes contains a
  credential is one refactor away from being logged.
  """
  def token(%{actor: actor}) do
    %{data: %{actor_id: actor.id, token: actor.token}}
  end

  @doc false
  def data(%Actor{} = actor) do
    %{
      id: actor.id,
      kind: actor.kind,
      name: actor.name,
      description: actor.description,
      enabled: actor.enabled,
      provider: actor.provider,
      model: actor.model,
      thinking_level: actor.thinking_level,
      system_prompt: actor.system_prompt,
      injection_profile: actor.injection_profile,
      inserted_at: actor.inserted_at,
      updated_at: actor.updated_at
    }
  end
end
