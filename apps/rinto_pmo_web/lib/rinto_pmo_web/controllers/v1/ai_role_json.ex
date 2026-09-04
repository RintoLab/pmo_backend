defmodule RintoPMOWeb.V1.AIRoleJSON do
  alias RintoPMO.AIRoles.AIRole

  def index(%{roles: roles}) do
    %{data: Map.new(roles, fn {key, role} -> {key, data(role)} end)}
  end

  @doc false
  def data(%AIRole{} = role) do
    %{
      id: role.id,
      key: role.key,
      provider: role.provider,
      model: role.model,
      thinking_level: role.thinking_level,
      # Null and `""` both mean the job runs on its own prompt alone. Rendered
      # as it was stored rather than normalised to one of them, so a client
      # gets back what it sent.
      system_prompt: role.system_prompt,
      inserted_at: role.inserted_at,
      updated_at: role.updated_at
    }
  end

  # A job nobody has configured. Not an empty object: the client's question is
  # "is this set up", and an object full of nulls answers it in six places
  # instead of one.
  def data(nil), do: nil
end
