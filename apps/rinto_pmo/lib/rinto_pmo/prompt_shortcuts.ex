defmodule RintoPMO.PromptShortcuts do
  @moduledoc """
  The quick prompts offered beside the composer.

  ## What this replaces

  A client used to carry these as a hard-coded table, keyed by what the message
  referenced. That works right up until somebody wants to reword one, and then
  it is a release. The set is small, it is edited by reading what the prompts
  came back with, and nothing about it is a client's business -- so it is rows.

  ## The client decides what to show, and in what order

  This context answers with all of them. Matching -- collect the reference
  types in the composer, keep the shortcuts whose `resource_type` is among them
  -- happens in the client, on a list it already holds.

  Filtering here was considered and refused: the composer's reference set
  changes on every mention added or removed, so a server-side filter would be a
  request per keystroke against a table of a dozen rows.

  Ordering is the client's for a duller reason: there is no `position` column,
  so the only order that exists is the one it receives. See
  `RintoPMO.PromptShortcuts.PromptShortcut` for the rest of what is absent.

  ## Editing versus seeding

  Two write paths that must not be confused.

  A caller creates, edits and deletes rows through here, and may touch neither
  `key` nor `default_prompt` -- the first is generated, the second belongs to
  the deployment.

  `RintoPMO.PromptShortcuts.Presets` writes the rows this system ships with,
  from a release task somebody runs by hand. That it can resurrect a row
  somebody deleted is the point of running it, which is exactly why it is not
  in `RintoPMO.Setup`: work that happens on boot resurrecting a deleted row is
  a bug, and the difference between the two is only ever who pressed the
  button.
  """

  use RintoPMO, :context

  alias RintoPMO.PromptShortcuts.PromptShortcut

  @doc """
  Every shortcut, oldest first.

  The whole set, always: a client replaces what it holds rather than merging,
  the way `RintoPMO.AIRoles` is read.
  """
  @spec list_shortcuts() :: [PromptShortcut.t()]
  def list_shortcuts do
    PromptShortcut
    |> order_by([shortcut], asc: shortcut.id)
    |> Repo.all()
  end

  @doc """
  Fetches one shortcut. Raises when it is not there.
  """
  @spec get_shortcut!(UUIDv7.t()) :: PromptShortcut.t()
  def get_shortcut!(id), do: Repo.get!(PromptShortcut, id)

  @doc """
  Fetches one shortcut by the key a deployment knows it by.
  """
  @spec get_shortcut_by_key(String.t()) :: PromptShortcut.t() | nil
  def get_shortcut_by_key(key) when is_binary(key), do: Repo.get_by(PromptShortcut, key: key)

  @doc """
  Creates a shortcut.

  `key` is generated and `default_prompt` is left null -- a row made here is
  nobody's default, so there is nothing for `reset_shortcut/1` to return it to.
  """
  @spec create_shortcut(map()) :: {:ok, PromptShortcut.t()} | {:error, Ecto.Changeset.t()}
  def create_shortcut(attrs) do
    attrs
    |> PromptShortcut.changeset()
    |> Repo.insert()
  end

  @doc """
  Edits a shortcut.

  Editing a preset's `prompt` is ordinary and is how a row stops tracking its
  default: from here on `prompt != default_prompt`, re-seeding leaves the
  wording alone, and `reset_shortcut/1` is the way back.
  """
  @spec update_shortcut(PromptShortcut.t(), map()) ::
          {:ok, PromptShortcut.t()} | {:error, Ecto.Changeset.t()}
  def update_shortcut(%PromptShortcut{} = shortcut, attrs) do
    shortcut
    |> PromptShortcut.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Deletes a shortcut, preset or not.

  A preset is deletable because a button nobody wants is a button nobody wants,
  and the way back is to run the seeding task again.
  """
  @spec delete_shortcut(PromptShortcut.t()) ::
          {:ok, PromptShortcut.t()} | {:error, Ecto.Changeset.t()}
  def delete_shortcut(%PromptShortcut{} = shortcut), do: Repo.delete(shortcut)

  @doc """
  Puts a preset's prompt back to what the deployment last wrote.

  Only the prompt. `label` and `icon` are whoever set them's -- a deployment
  writes them once and never again -- so a renamed button stays renamed.

  Refuses a row with no default: it was created through the API and has no
  earlier wording that anybody but its author chose.
  """
  @spec reset_shortcut(PromptShortcut.t()) ::
          {:ok, PromptShortcut.t()} | {:error, :not_a_preset, map()}
  def reset_shortcut(%PromptShortcut{default_prompt: nil}), do: {:error, :not_a_preset, %{}}

  def reset_shortcut(%PromptShortcut{} = shortcut) do
    shortcut
    |> PromptShortcut.changeset(%{"prompt" => shortcut.default_prompt})
    |> Repo.update()
  end

  @doc false
  @spec insert_preset(map()) :: {:ok, PromptShortcut.t()} | {:error, Ecto.Changeset.t()}
  def insert_preset(attrs) do
    %PromptShortcut{}
    |> PromptShortcut.preset_changeset(attrs)
    |> Repo.insert()
  end

  @doc false
  @spec update_preset(PromptShortcut.t(), map()) ::
          {:ok, PromptShortcut.t()} | {:error, Ecto.Changeset.t()}
  def update_preset(%PromptShortcut{} = shortcut, attrs) do
    shortcut
    |> PromptShortcut.preset_changeset(attrs)
    |> Repo.update()
  end
end
