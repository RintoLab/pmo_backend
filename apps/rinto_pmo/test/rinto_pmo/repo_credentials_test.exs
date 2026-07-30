defmodule RintoPMO.RepoCredentialsTest do
  use RintoPMO.DataCase, async: true

  alias RintoPMO.Projects.ProjectRepo
  alias RintoPMO.RepoCredentials
  alias RintoPMO.RepoCredentials.RepoCredential

  describe "repository credentials" do
    test "creates, lists, and fetches a credential" do
      assert {:ok, %RepoCredential{} = credential} =
               RepoCredentials.create_repo_credential(%{
                 name: "GitHub",
                 username: "git-user",
                 token: "secret-token"
               })

      assert RepoCredentials.get_repo_credential!(credential.id).id == credential.id
      assert Enum.map(RepoCredentials.list_repo_credentials(), & &1.id) == [credential.id]
    end

    test "requires username and token" do
      for field <- [:username, :token] do
        attrs =
          %{name: "GitHub", username: "git-user", token: "secret-token"}
          |> Map.delete(field)

        assert {:error, changeset} = RepoCredentials.create_repo_credential(attrs)
        assert "can't be blank" in errors_on(changeset)[field]
      end
    end

    test "updates metadata without clearing an omitted token" do
      credential = insert(:repo_credential, token: "original-token")

      assert {:ok, updated} =
               RepoCredentials.update_repo_credential(credential, %{
                 name: "Updated",
                 username: "updated-user"
               })

      assert updated.name == "Updated"
      assert updated.username == "updated-user"
      assert updated.token == "original-token"
    end

    test "deletes a credential and clears all repository references" do
      credential = insert(:repo_credential)
      first_repo = insert(:project_repo, credential: credential)
      second_repo = insert(:project_repo, credential: credential)

      assert {:ok, deleted} = RepoCredentials.delete_repo_credential(credential)
      assert deleted.id == credential.id
      assert Repo.get(RepoCredential, credential.id) == nil
      assert Repo.get!(ProjectRepo, first_repo.id).credential_id == nil
      assert Repo.get!(ProjectRepo, second_repo.id).credential_id == nil
    end
  end
end
