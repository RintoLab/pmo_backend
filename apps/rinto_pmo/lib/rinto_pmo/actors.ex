defmodule RintoPMO.Actors do
  @moduledoc """
  The context for human participants and AI personas.

  ## Who is calling

  `authenticate/1` turns a token into the person holding it, and is the only
  way anything upstream learns who is making a request. It is deliberately
  small: this system has one person in it, so there is no session to establish
  and nothing to expire.

  Tokens are stored as they are sent. Hashing them would buy nothing here --
  the database and the token live on the same machine, under the same person,
  and being able to read the token back is what makes
  `mix rinto.actors.setup_human` able to print it a second time instead of
  forcing a rotation on somebody who merely closed a terminal.
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
    @callback create_actor(map()) :: {:ok, Actor.t()} | {:error, Ecto.Changeset.t()}
    @callback update_actor(Actor.t(), map()) ::
                {:ok, Actor.t()} | {:error, Ecto.Changeset.t()}

    # `authenticate/1` and `issue_token/1` are deliberately absent. They are
    # how the system decides whether to answer at all, and are called on the
    # real module everywhere -- a test that could stub out authentication would
    # be testing a build of the application that nobody runs.
  end

  @behaviour Behaviour

  # 32 bytes because the token is the entire authentication story: there is no
  # rate limit in front of it and no second factor behind it.
  @token_bytes 32

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
  The person holding `token`.

  Distinguishes "wrong token" from "no token has ever been issued" because the
  two have different answers: the first is a client that needs fixing, the
  second is a server nobody has run `mix rinto.actors.setup_human` against yet,
  and saying so saves an afternoon. That distinction leaks nothing worth
  keeping -- an installation with no token has nothing in it to protect.

  Candidates are compared in constant time rather than looked up by the unique
  index, so that the reply time does not report how much of a guessed token was
  right.
  """
  @spec authenticate(term()) ::
          {:ok, Actor.t()} | {:error, :unauthorized} | {:error, :token_not_configured}
  def authenticate(token) when is_binary(token) do
    case tokened_humans() do
      [] ->
        {:error, :token_not_configured}

      humans ->
        case Enum.find(humans, &secure_equal?(&1.token, token)) do
          nil -> {:error, :unauthorized}
          actor -> {:ok, actor}
        end
    end
  end

  def authenticate(_absent_or_malformed) do
    case tokened_humans() do
      [] -> {:error, :token_not_configured}
      _issued -> {:error, :unauthorized}
    end
  end

  @doc """
  Issues a freshly generated token to a human actor.

  There is no way to supply one. A token somebody can choose is a token
  somebody eventually chooses badly, and this is the whole of authentication --
  no rate limit in front of it, no second factor behind it. Generating is the
  only path, so its strength is not a decision anybody has to get right.

  Rotating is the same operation as issuing: nothing is revoked separately,
  because the old token stops working the moment this returns.
  """
  @spec issue_token(Actor.t()) :: {:ok, Actor.t()} | {:error, Ecto.Changeset.t()}
  def issue_token(%Actor{} = actor) do
    actor
    |> Actor.token_changeset(generate_token())
    |> Repo.update()
  end

  @doc """
  A fresh token, in a shape that survives being pasted into a shell or a URL.
  """
  @spec generate_token() :: String.t()
  def generate_token do
    @token_bytes |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
  end

  # `:crypto.hash_equals/2` refuses binaries of different sizes, so length is
  # checked first. Length is not a secret worth protecting: every token this
  # system issues is the same size, so a wrong one is wrong on its contents.
  defp secure_equal?(issued, given) do
    byte_size(issued) == byte_size(given) and :crypto.hash_equals(issued, given)
  end

  defp tokened_humans do
    Actor
    |> where([actor], actor.kind == :human and not is_nil(actor.token))
    |> Repo.all()
  end
end
