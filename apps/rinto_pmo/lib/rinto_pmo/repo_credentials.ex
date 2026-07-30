defmodule RintoPMO.RepoCredentials do
  @moduledoc """
  The context for reusable Git HTTPS credentials.
  """

  use RintoPMO, :context

  alias RintoPMO.RepoCredentials.RepoCredential

  defmodule Behaviour do
    @moduledoc false

    alias RintoPMO.RepoCredentials.RepoCredential

    @callback list_repo_credentials() :: [RepoCredential.t()]
    @callback get_repo_credential!(UUIDv7.t()) :: RepoCredential.t()
    @callback create_repo_credential(map()) ::
                {:ok, RepoCredential.t()} | {:error, Ecto.Changeset.t()}
    @callback update_repo_credential(RepoCredential.t(), map()) ::
                {:ok, RepoCredential.t()} | {:error, Ecto.Changeset.t()}
    @callback delete_repo_credential(RepoCredential.t()) ::
                {:ok, RepoCredential.t()} | {:error, Ecto.Changeset.t()}
  end

  @behaviour Behaviour

  @doc """
  Lists all repository credentials.
  """
  @impl true
  def list_repo_credentials do
    RepoCredential
    |> order_by([credential], asc: credential.name)
    |> Repo.all()
  end

  @doc """
  Fetches a repository credential by id.
  """
  @impl true
  def get_repo_credential!(id), do: Repo.get!(RepoCredential, id)

  @doc """
  Creates a repository credential.
  """
  @impl true
  def create_repo_credential(attrs) do
    attrs
    |> RepoCredential.changeset()
    |> Repo.insert()
  end

  @doc """
  Updates a repository credential. An omitted token retains its current value.
  """
  @impl true
  def update_repo_credential(%RepoCredential{} = credential, attrs) do
    credential
    |> RepoCredential.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Deletes a credential. Database foreign keys clear repository references.
  """
  @impl true
  def delete_repo_credential(%RepoCredential{} = credential) do
    Repo.delete(credential)
  end
end
