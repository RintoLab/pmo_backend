defmodule RintoPMO.AIRoles do
  @moduledoc """
  Background AI work and the model configuration for each job.

  Not a catalogue of system-wide roles. These jobs share a narrow boundary, and
  what they have in common is narrow and worth stating: **neither happens
  inside a conversation**. Everything else a model does in this system is asked
  for by somebody who is talking to it, and takes its configuration from the
  topic they are talking in.

    * `"topic_naming"` -- a topic gets a title from its first message. Nobody
      asks for it; it happens because a topic without a name is unusable.
    * `"task_estimation"` -- a task is rated for difficulty, or given a
      three-point estimate. Asked for, but in bulk and against a subtree, and
      what comes back is numbers written into columns and fed to calibration.
    * `"requirement_prioritization"` -- sets a single requirement priority
      directly; users can correct it manually.

  The jobs that used to be here -- breaking a document down, answering an
  annotation, reviewing a set of documents -- were none of that. Each was one
  person clicking one button about one thing, which is a conversation with an
  extra step, and each is now a prompt shortcut sent in a topic. See
  `docs/implementation-plan-prompt-shortcuts.md`.

  ## Configuration, not a pointer

  A row holds a provider, a model, a thinking level and an optional standing
  instruction. It used to hold an actor id instead, and read those four off
  whichever persona was chosen. `RintoPMO.AIRoles.AIRole` says why that came
  apart.

  What it means here is that the write side got simpler in a way worth noting,
  because the old module made a lot of it: there is no longer a rule about
  humans, disabled actors or the stand-in. A configuration cannot be the wrong
  kind of thing to be a configuration. What is left is one validation -- the
  three model fields arrive together -- and it lives on the changeset.

  ## An empty role is an ordinary state, and readers differ

  A role may never have been configured, and may be emptied at any time with
  `delete_role/1`. What that means is the reader's to decide, and they answer
  differently because their situations differ:

    * `RintoPMO.Conversations.Titles` falls back to the topic's own model
      configuration. Naming happens inside a conversation, so there is always
      another configuration right there to inherit -- one whose credentials are
      known to work, since the person is already talking through it.
    * `RintoPMO.Tasks` and `RintoPMO.Requirements.Prioritization` refuse.
      Estimation and prioritization belong to no conversation, so there
      is nothing to fall back *to*, and picking a provider off the catalogue
      would be this module inventing an answer nobody gave it.

  Neither is a rule about roles in general.

  ## Why the set is fixed

  `keys/0` is the whole of it, and there is no way to create a row under any
  other key. A role exists because code reads it: `Titles` asks for
  `"topic_naming"` by name. A row under a key nothing reads would be
  configuration for a job that does not happen -- editable, renderable, and
  dead. So the catalogue is a code change, and what the API offers is the
  ordinary three: read them, write one, empty one.
  """

  use RintoPMO, :context

  alias RintoPMO.AIRoles.AIRole

  @typedoc """
  A job this system does on its own.
  """
  @type key :: String.t()

  @keys ~w(topic_naming task_estimation requirement_prioritization)

  @doc """
  The jobs that exist.
  """
  @spec keys() :: [key()]
  def keys, do: @keys

  @doc """
  Whether `key` is a job this system has.
  """
  @spec known_key?(term()) :: boolean()
  def known_key?(key), do: key in @keys

  @doc """
  Every job and its configuration, with `nil` for the ones nobody has set up.

  Always answers with every known key, so a client renders the same list
  whether or not anybody has ever configured anything.
  """
  @spec list_roles() :: %{key() => AIRole.t() | nil}
  def list_roles do
    configured =
      AIRole
      |> where([role], role.key in ^@keys)
      |> Repo.all()
      |> Map.new(&{&1.key, &1})

    Map.new(@keys, fn key -> {key, Map.get(configured, key)} end)
  end

  @doc """
  How `key` calls a model, or `nil` when nobody has configured it.
  """
  @spec get_role(key()) :: AIRole.t() | nil
  def get_role(key) when is_binary(key), do: Repo.get_by(AIRole, key: key)

  @doc """
  Configures a job, replacing whatever was there.

  A `PUT` in every sense: the row is written whole, so a request that leaves
  `system_prompt` out clears it rather than keeping the old one. Partial edits
  are not offered because there is nothing here to edit *around* -- four fields,
  all of them on one form, and a client that could send three of them would be
  a client that can save a screen it never read.

  Returns the full set, so a caller replaces what it is holding.
  """
  @spec put_role(key(), map()) ::
          {:ok, %{key() => AIRole.t() | nil}}
          | {:error, :not_found}
          | {:error, Ecto.Changeset.t()}
  def put_role(key, attrs) when is_binary(key) and is_map(attrs) do
    if known_key?(key) do
      key
      |> existing()
      |> AIRole.changeset(written_whole(attrs, key))
      |> Repo.insert_or_update()
      |> case do
        {:ok, _role} -> {:ok, list_roles()}
        {:error, _changeset} = error -> error
      end
    else
      # An unknown job is not a validation failure on the body; there is no
      # such role to write to.
      {:error, :not_found}
    end
  end

  @doc """
  Empties a job, so that it falls back or refuses.

  Deleting the row rather than nulling its columns: a row of nulls and no row
  are the same state, and keeping one of them around would mean every reader
  had to know both. Emptying something that was already empty succeeds --
  what was asked for is true either way.

  Returns the full set, for the same reason `put_role/2` does.
  """
  @spec delete_role(key()) :: {:ok, %{key() => AIRole.t() | nil}} | {:error, :not_found}
  def delete_role(key) when is_binary(key) do
    if known_key?(key) do
      AIRole
      |> where([role], role.key == ^key)
      |> Repo.delete_all()

      {:ok, list_roles()}
    else
      {:error, :not_found}
    end
  end

  defp existing(key), do: Repo.get_by(AIRole, key: key) || %AIRole{}

  # `key` comes from the URL, never from the body: a caller that could send one
  # could move a row to the other job by editing this one.
  #
  # `system_prompt` is defaulted in rather than left out, because `cast/3`
  # leaves an absent field alone and this is a `PUT`. Without the default,
  # clearing a standing instruction would be the one edit the API cannot
  # express -- and the textarea the client shows as empty would keep working.
  defp written_whole(attrs, key) do
    attrs
    |> stringify()
    |> Map.put_new("system_prompt", nil)
    |> Map.put("key", key)
  end

  # The attributes come from a JSON body, so they are strings. A caller inside
  # the system may pass atoms, and mixing the two in one map is the one way
  # `cast/3` silently drops fields.
  defp stringify(attrs) do
    Map.new(attrs, fn {field, value} -> {to_string(field), value} end)
  end
end
