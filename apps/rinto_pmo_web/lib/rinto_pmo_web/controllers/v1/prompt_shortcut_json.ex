defmodule RintoPMOWeb.V1.PromptShortcutJSON do
  alias RintoPMO.PromptShortcuts.PromptShortcut

  def index(%{shortcuts: shortcuts}) do
    %{data: Enum.map(shortcuts, &data/1)}
  end

  def show(%{shortcut: shortcut}) do
    %{data: data(shortcut)}
  end

  @doc false
  def data(%PromptShortcut{} = shortcut) do
    %{
      id: shortcut.id,
      # Stable across deployments, and not something to branch on: it is here
      # so a client can tell two rows apart across a re-seed, not so it can
      # recognise one.
      key: shortcut.key,
      # Null means "offer this when nothing is referenced".
      resource_type: shortcut.resource_type,
      label: shortcut.label,
      icon: shortcut.icon,
      prompt: shortcut.prompt,
      # Both values, so that "has this been edited?" is a comparison the client
      # makes rather than a flag this has to keep true. Null means the row was
      # created through this API and has no default to reset to.
      default_prompt: shortcut.default_prompt,
      inserted_at: shortcut.inserted_at,
      updated_at: shortcut.updated_at
    }
  end
end
