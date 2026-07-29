defmodule RintoPMOWeb.V1.ActorJSON do
  alias RintoPMO.Actors.Actor

  def index(%{actors: actors}) do
    %{data: Enum.map(actors, &data/1)}
  end

  def show(%{actor: actor}) do
    %{data: data(actor)}
  end

  defp data(%Actor{} = actor) do
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
