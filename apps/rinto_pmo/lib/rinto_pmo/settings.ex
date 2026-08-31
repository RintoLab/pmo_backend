defmodule RintoPMO.Settings do
  @moduledoc """
  Which actor plays each system-wide role.

  ## Why this is not configuration

  The jobs here are answered by "that one", not by "this value": which persona
  names topics is a choice somebody makes while looking at the list of actors,
  changes their mind about after seeing a few titles, and changes back. Put in
  `config.exs` that is a deploy; put here it is one request, and the answer is
  visible next to the actors it is choosing between.

  ## A role is a pointer, and can be empty

  A role may be unset, may point at an actor that has since been deleted (the
  column is nulled, not the row), and may point at one that has since been
  disabled. All three read as `nil` from `get_actor/1`, which is why nothing
  here has to be kept in step with the actors table.

  What an empty role means is the reader's to decide, and the two readers
  answer differently because their situations differ:

    * `RintoPMO.Conversations.Titles` falls back to the topic's own assistant
      configuration, whether that is a fixed actor or a plain chat model.
      Naming happens inside a conversation, so there is always another model
      configuration right there to inherit from.
    * decomposing a document, or estimating a task, refuses outright. Those
      jobs belong to no conversation, so there is nothing to fall back *to*,
      and picking some actor off the list would be this module inventing an
      answer nobody gave it.

  Neither is a rule about roles in general. An empty role is an ordinary state;
  what to do about it is a question about the job, not about the pointer.

  Being strict at write time and lenient at read time is deliberate:
  `put_actor/2` refuses a human or a disabled actor so that the mistake is
  reported to whoever is making it, while a change made later to an actor that
  was fine when chosen must not break naming for everyone.
  """

  use RintoPMO, :context

  alias Ecto.Changeset
  alias RintoPMO.Actors.Actor
  alias RintoPMO.Settings.SystemSetting

  @typedoc """
  The roles the system knows how to fill.

  * `"title_actor"` -- names topics from their first message
  * `"decomposition_actor"` -- breaks a formal document down into a task
    document. Unlike naming, this one has no fallback: see above.
  * `"estimation_actor"` -- rates a task's difficulty or produces its
    three-point estimate. Same as decomposition: it belongs to no conversation,
    so an empty role is a refusal rather than a fallback.
  * `"annotation_actor"` -- answers one annotation when somebody asks it to.
    Refuses when empty, for the same reason: a person clicked a button on a
    note, not inside a topic, so there is no assistant standing there to
    inherit from.
  """
  @type key :: String.t()

  @keys ~w(title_actor decomposition_actor estimation_actor annotation_actor)

  @doc """
  The roles that exist.
  """
  @spec keys() :: [key()]
  def keys, do: @keys

  @doc """
  Whether `key` is a role this system has.
  """
  @spec known_key?(term()) :: boolean()
  def known_key?(key), do: key in @keys

  @doc """
  Every role and the actor in it, with `nil` for the empty ones.

  Always answers with every known role, so a client renders the same list
  whether or not anybody has ever chosen anything.
  """
  @spec list_settings() :: %{key() => Actor.t() | nil}
  def list_settings do
    chosen =
      SystemSetting
      |> join(:inner, [setting], actor in assoc(setting, :actor))
      |> where([_setting, actor], actor.enabled == true)
      |> select([setting, actor], {setting.key, actor})
      |> Repo.all()
      |> Map.new()

    Map.new(@keys, fn key -> {key, Map.get(chosen, key)} end)
  end

  @doc """
  The actor playing `key`, or `nil` when the role is empty.

  A disabled actor is nobody: turning an actor off is how somebody takes it out
  of service, and it would be a strange kind of off that kept naming topics.
  """
  @spec get_actor(key()) :: Actor.t() | nil
  def get_actor(key) when is_binary(key) do
    SystemSetting
    |> where([setting], setting.key == ^key)
    |> join(:inner, [setting], actor in assoc(setting, :actor))
    |> where([_setting, actor], actor.enabled == true)
    |> select([_setting, actor], actor)
    |> Repo.one()
  end

  @doc """
  Puts an actor in a role, or empties it with `nil`.

  Returns the full set of roles, so a caller replaces what it is holding rather
  than patching it.
  """
  @spec put_actor(key(), UUIDv7.t() | nil) ::
          {:ok, %{key() => Actor.t() | nil}} | {:error, :not_found} | {:error, Ecto.Changeset.t()}
  def put_actor(key, actor_id) do
    if known_key?(key) do
      key
      |> existing()
      |> SystemSetting.changeset(%{key: key, actor_id: actor_id})
      |> validate_actor()
      |> Repo.insert_or_update()
      |> case do
        {:ok, _setting} -> {:ok, list_settings()}
        {:error, _changeset} = error -> error
      end
    else
      # An unknown role is not a validation failure on the body; there is no
      # such setting to write to.
      {:error, :not_found}
    end
  end

  defp existing(key) do
    Repo.get_by(SystemSetting, key: key) || %SystemSetting{}
  end

  # Checked here rather than by a constraint: "an enabled AI actor" is a rule
  # about what can do the job, and the database has no opinion about that.
  #
  # Read through the changeset rather than from the argument, so an id that is
  # not an id has already been rejected by the cast and is not also reported as
  # missing.
  defp validate_actor(changeset) do
    case Changeset.get_field(changeset, :actor_id) do
      nil ->
        changeset

      actor_id ->
        case Repo.get(Actor, actor_id) do
          nil -> Changeset.add_error(changeset, :actor_id, "does not exist")
          %Actor{kind: :human} -> Changeset.add_error(changeset, :actor_id, "must be an AI actor")
          %Actor{enabled: false} -> Changeset.add_error(changeset, :actor_id, "is disabled")
          %Actor{} -> changeset
        end
    end
  end
end
