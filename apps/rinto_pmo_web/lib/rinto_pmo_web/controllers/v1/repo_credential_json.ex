defmodule RintoPMOWeb.V1.RepoCredentialJSON do
  alias RintoPMO.RepoCredentials.RepoCredential

  def index(%{repo_credentials: repo_credentials}) do
    %{data: Enum.map(repo_credentials, &data/1)}
  end

  def show(%{repo_credential: repo_credential}) do
    %{data: data(repo_credential)}
  end

  defp data(%RepoCredential{} = repo_credential) do
    %{
      id: repo_credential.id,
      name: repo_credential.name,
      username: repo_credential.username,
      inserted_at: repo_credential.inserted_at,
      updated_at: repo_credential.updated_at
    }
  end
end
