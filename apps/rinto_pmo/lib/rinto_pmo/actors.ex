defmodule RintoPMO.Actors do
  @moduledoc """
  The context for human participants and AI personas.

  ## Who is calling

  `authenticate/1` decides whether a request is answered at all, and is the
  only way anything upstream learns who is making one. It is deliberately
  small: this system has one person in it, so there is no session to establish
  and nothing to expire.

  ## The token is configuration, not data

  One token, agreed in advance, given to the server as `RINTO_TOKEN` and
  written by hand into the configuration of everything that calls it -- the
  CLI, the editor, the browser. Nothing here issues, stores, or hands one out.

  That is what the shape of this system actually is. A token cannot be
  *distributed* from here: every client keeps its own copy in its own config
  file, so a copy in the database would be a fourth place to keep in step with
  the other three rather than the source any of them read. Rotating is the
  same story -- it happens outside, by changing the agreed value and restarting
  what holds it, so there is nothing here to rotate.

  ## And who that makes you

  The token says only "the person this installation belongs to", so
  `get_owner/0` is what turns it into an actor: the earliest-created human,
  which in a system set up the ordinary way is the only one there is. A second
  human is a record of a colleague rather than a second way in -- there is one
  credential, so there is one caller.
  """

  use RintoPMO, :context

  alias RintoPMO.Actors.Actor

  defmodule Behaviour do
    @moduledoc false

    alias RintoPMO.Actors.Actor

    @callback list_actors() :: [Actor.t()]
    @callback get_unique_human() ::
                {:ok, Actor.t()}
                | {:error, :human_actor_not_found}
                | {:error, :human_actor_ambiguous, map()}
    @callback get_actor!(UUIDv7.t()) :: Actor.t()
    @callback get_default_assistant() :: Actor.t() | nil
    @callback create_actor(map()) :: {:ok, Actor.t()} | {:error, Ecto.Changeset.t()}
    @callback update_actor(Actor.t(), map()) ::
                {:ok, Actor.t()} | {:error, Ecto.Changeset.t()}

    # `authenticate/1` and `get_owner/0` are deliberately absent. They are how
    # the system decides whether to answer at all, and are called on the real
    # module everywhere -- a test that could stub out authentication would be
    # testing a build of the application that nobody runs.
  end

  @behaviour Behaviour

  @doc """
  Lists all actors.
  """
  @impl true
  def list_actors do
    Actor
    |> order_by([actor], asc: actor.name)
    |> Repo.all()
  end

  @doc """
  Fetches the system's only human participant.

  This is the pre-authentication identity used by local clients. Refusing zero
  or several humans is deliberate: choosing an arbitrary person would
  attribute documents and completed work to the wrong user.
  """
  @impl true
  def get_unique_human do
    humans =
      Actor
      |> where([actor], actor.kind == :human)
      |> order_by([actor], asc: actor.inserted_at)
      |> Repo.all()

    case humans do
      [human] ->
        {:ok, human}

      [] ->
        {:error, :human_actor_not_found}

      several ->
        {:error, :human_actor_ambiguous,
         %{actor_ids: Enum.map(several, & &1.id), count: length(several)}}
    end
  end

  @doc """
  Fetches an actor by id, raising when it does not exist.
  """
  @impl true
  def get_actor!(id), do: Repo.get!(Actor, id)

  @doc """
  The actor that stands in for an AI nobody named, or `nil` before setup ran.

  Not raising, unlike `get_actor!/1`: its absence means this installation has
  not been set up, which is a refusal the caller renders rather than a bug --
  the same shape `RintoPMO.Projects.get_default_project/0` has.

  A disabled one still answers. Turning it off cannot un-write the blocks
  already signed with it, and refusing to sign the next one would only produce
  a document nobody can attribute.
  """
  @impl true
  def get_default_assistant, do: Repo.get_by(Actor, default: true)

  @doc """
  Creates an actor.
  """
  @impl true
  def create_actor(attrs) do
    attrs
    |> Actor.changeset()
    |> Repo.insert()
  end

  @doc """
  Updates an actor.
  """
  @impl true
  def update_actor(%Actor{} = actor, attrs) do
    actor
    |> Actor.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  The person calling, given the token the request carried.

  Three refusals rather than one, because they are three different people's
  problems:

    * `:token_not_configured` -- the server was started without `RINTO_TOKEN`,
      so it has nothing to check against and answers nothing. An operator's
      problem
    * `:unauthorized` -- the token is absent, malformed, or wrong. The caller's
      problem
    * `:human_actor_missing` -- the token is right, but nobody has run
      `mix rinto.actors.setup_human` against this database, so there is no
      person to attribute the request to. An operator's problem again

  Saying which leaks nothing worth keeping: the first and third describe an
  installation that has nothing in it to protect, and the second says only that
  a guess was wrong.

  The comparison is constant time, so the reply does not report how much of a
  guessed token was right.
  """
  @spec authenticate(term()) ::
          {:ok, Actor.t()}
          | {:error, :unauthorized}
          | {:error, :token_not_configured}
          | {:error, :human_actor_missing}
  def authenticate(token) do
    case configured_token() do
      nil -> {:error, :token_not_configured}
      configured -> resolve(configured, token)
    end
  end

  @doc """
  The token this installation answers to, or `nil` if it was given none.

  Configuration, set from `RINTO_TOKEN` in `config/runtime.exs`. A server
  without one is not a server with an open door: `authenticate/1` refuses
  everything, because it has nothing to compare against.
  """
  @spec configured_token() :: String.t() | nil
  def configured_token do
    :rinto_pmo
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:token)
    |> presence()
  end

  @doc """
  The human this installation belongs to, or `nil` before there is one.

  The earliest-created human, which is the one `mix rinto.actors.setup_human`
  makes and, in a system set up the ordinary way, the only one there is. Later
  humans are colleagues on the record rather than callers: there is a single
  token, so there is a single caller, and picking the first is a definition
  rather than a guess between candidates.
  """
  @spec get_owner() :: Actor.t() | nil
  def get_owner do
    Actor
    |> where([actor], actor.kind == :human)
    |> order_by([actor], asc: actor.inserted_at, asc: actor.id)
    |> limit(1)
    |> Repo.one()
  end

  defp resolve(configured, given) when is_binary(given) do
    if secure_equal?(configured, given), do: owner(), else: {:error, :unauthorized}
  end

  defp resolve(_configured, _absent_or_malformed), do: {:error, :unauthorized}

  defp owner do
    case get_owner() do
      nil -> {:error, :human_actor_missing}
      actor -> {:ok, actor}
    end
  end

  # `:crypto.hash_equals/2` refuses binaries of different sizes, so length is
  # checked first. That reveals the configured token's length to somebody
  # guessing, which is worth less than it sounds: the value is chosen by an
  # operator rather than found by search, and a wrong one of the right length
  # is still wrong on its contents.
  defp secure_equal?(configured, given) do
    byte_size(configured) == byte_size(given) and :crypto.hash_equals(configured, given)
  end

  defp presence(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp presence(_absent), do: nil
end
