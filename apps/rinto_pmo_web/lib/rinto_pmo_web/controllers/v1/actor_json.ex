defmodule RintoPMOWeb.V1.ActorJSON do
  alias RintoPMO.Actors.Actor

  def index(%{actors: actors}) do
    %{data: Enum.map(actors, &data/1)}
  end

  def show(%{actor: actor}) do
    %{data: data(actor)}
  end

  @doc false
  def data(%Actor{} = actor) do
    %{
      id: actor.id,
      kind: actor.kind,
      name: actor.name,
      description: actor.description,
      enabled: actor.enabled,
      # What a plain chat's writing is signed with. It has no model, so it
      # cannot be a topic's assistant and cannot hold a role -- a client
      # offering either should leave it out of the list.
      default: actor.default,
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
