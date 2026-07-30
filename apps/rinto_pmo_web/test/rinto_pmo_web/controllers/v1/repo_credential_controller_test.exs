defmodule RintoPMOWeb.V1.RepoCredentialControllerTest do
  use RintoPMOWeb.ConnCase, async: true

  alias RintoPMO.RepoCredentials.RepoCredential
  alias RintoPMO.RepoCredentialsMock

  test "GET /api/v1/repo_credentials lists credentials without tokens", %{conn: conn} do
    credential =
      insert(:repo_credential,
        name: "GitHub",
        token: "never-return-this"
      )

    credential_id = credential.id
    expect(RepoCredentialsMock, :list_repo_credentials, fn -> [credential] end)

    conn = get(conn, ~p"/api/v1/repo_credentials")

    assert [%{"id" => ^credential_id, "name" => "GitHub"} = data] =
             json_response(conn, 200)["data"]

    refute Map.has_key?(data, "token")
    refute response(conn, 200) =~ "never-return-this"
  end

  test "GET /api/v1/repo_credentials/:id shows a credential without its token", %{conn: conn} do
    credential = insert(:repo_credential, token: "secret-token")
    credential_id = credential.id

    expect(RepoCredentialsMock, :get_repo_credential!, fn id ->
      assert id == credential.id
      credential
    end)

    conn = get(conn, ~p"/api/v1/repo_credentials/#{credential.id}")

    assert %{"id" => ^credential_id, "username" => username} =
             json_response(conn, 200)["data"]

    assert username == credential.username
    refute response(conn, 200) =~ "secret-token"
  end

  test "POST /api/v1/repo_credentials creates a credential without echoing token", %{conn: conn} do
    credential =
      insert(:repo_credential, name: "GitHub", username: "git-user", token: "secret-token")

    params = %{"name" => "GitHub", "username" => "git-user", "token" => "secret-token"}

    expect(RepoCredentialsMock, :create_repo_credential, fn ^params -> {:ok, credential} end)

    conn = post(conn, ~p"/api/v1/repo_credentials", repo_credential: params)

    assert %{"name" => name} = data = json_response(conn, 201)["data"]
    assert name == credential.name
    refute Map.has_key?(data, "token")
    refute response(conn, 201) =~ "secret-token"
  end

  test "PATCH /api/v1/repo_credentials/:id updates without requiring token in params", %{
    conn: conn
  } do
    credential = insert(:repo_credential, name: "Old")
    params = %{"name" => "Updated"}
    updated = %{credential | name: "Updated"}

    expect(RepoCredentialsMock, :get_repo_credential!, fn id ->
      assert id == credential.id
      credential
    end)

    expect(RepoCredentialsMock, :update_repo_credential, fn ^credential, ^params ->
      {:ok, updated}
    end)

    conn =
      patch(conn, ~p"/api/v1/repo_credentials/#{credential.id}", repo_credential: params)

    assert %{"name" => "Updated"} = json_response(conn, 200)["data"]
  end

  test "DELETE /api/v1/repo_credentials/:id returns 204", %{conn: conn} do
    credential = insert(:repo_credential)

    expect(RepoCredentialsMock, :get_repo_credential!, fn id ->
      assert id == credential.id
      credential
    end)

    expect(RepoCredentialsMock, :delete_repo_credential, fn ^credential -> {:ok, credential} end)

    conn = delete(conn, ~p"/api/v1/repo_credentials/#{credential.id}")

    assert response(conn, 204) == ""
  end

  test "POST /api/v1/repo_credentials returns validation errors", %{conn: conn} do
    params = %{"name" => "Missing fields"}
    changeset = RepoCredential.changeset(params)

    expect(RepoCredentialsMock, :create_repo_credential, fn ^params -> {:error, changeset} end)

    conn = post(conn, ~p"/api/v1/repo_credentials", repo_credential: params)

    assert %{
             "error" => "validation_error",
             "message" => "Request validation failed.",
             "details" => %{
               "token" => ["can't be blank"],
               "username" => ["can't be blank"]
             }
           } = json_response(conn, 422)
  end

  test "GET /api/v1/repo_credentials/:id returns 404", %{conn: conn} do
    id = UUIDv7.generate()

    expect(RepoCredentialsMock, :get_repo_credential!, fn ^id ->
      raise Ecto.NoResultsError, queryable: RepoCredential
    end)

    assert {404, _headers, _body} =
             assert_error_sent(:not_found, fn ->
               get(conn, ~p"/api/v1/repo_credentials/#{id}")
             end)
  end

  test "token is filtered from logged request parameters" do
    assert %{"token" => "[FILTERED]", "username" => "git-user"} =
             Phoenix.Logger.filter_values(%{
               "token" => "secret-token",
               "username" => "git-user"
             })
  end
end
