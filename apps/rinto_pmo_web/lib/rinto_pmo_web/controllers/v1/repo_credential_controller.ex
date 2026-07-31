defmodule RintoPMOWeb.V1.RepoCredentialController do
  use RintoPMOWeb, :controller

  alias RintoPMO.Utils

  def index(conn, _params) do
    repo_credentials = repo_credentials_context().list_repo_credentials()

    render(conn, :index, repo_credentials: repo_credentials)
  end

  def show(conn, %{"id" => id}) do
    repo_credential = repo_credentials_context().get_repo_credential!(id)

    render(conn, :show, repo_credential: repo_credential)
  end

  def create(conn, params) do
    with {:ok, repo_credential} <-
           repo_credentials_context().create_repo_credential(params) do
      conn
      |> put_status(:created)
      |> render(:show, repo_credential: repo_credential)
    end
  end

  def update(conn, %{"id" => id} = params) do
    context = repo_credentials_context()
    repo_credential = context.get_repo_credential!(id)
    repo_credential_params = Map.delete(params, "id")

    with {:ok, repo_credential} <-
           context.update_repo_credential(repo_credential, repo_credential_params) do
      render(conn, :show, repo_credential: repo_credential)
    end
  end

  def delete(conn, %{"id" => id}) do
    context = repo_credentials_context()
    repo_credential = context.get_repo_credential!(id)

    with {:ok, _repo_credential} <- context.delete_repo_credential(repo_credential) do
      send_resp(conn, :no_content, "")
    end
  end

  defp repo_credentials_context, do: Utils.module(:repo_credentials)
end
