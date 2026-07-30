defmodule RintoPMO.RepoCredentials.RepoCredentialTest do
  use RintoPMO.DataCase, async: true

  alias RintoPMO.RepoCredentials.RepoCredential

  describe "changeset/2" do
    test "accepts the HTTPS credential fields" do
      changeset = RepoCredential.changeset(valid_attrs())

      assert changeset.valid?
    end

    test "requires name, username, and token" do
      for field <- [:name, :username, :token] do
        changeset = valid_attrs() |> Map.delete(field) |> RepoCredential.changeset()

        refute changeset.valid?
        assert "can't be blank" in errors_on(changeset)[field]
      end
    end

    test "retains an existing token when an update omits it" do
      credential = build(:repo_credential, token: "original-token")
      changeset = RepoCredential.changeset(credential, %{name: "Updated"})

      assert changeset.valid?
      assert Ecto.Changeset.get_field(changeset, :token) == "original-token"
    end

    test "does not allow clearing an existing token" do
      credential = build(:repo_credential, token: "original-token")
      changeset = RepoCredential.changeset(credential, %{token: nil})

      refute changeset.valid?
      assert "can't be blank" in errors_on(changeset).token
    end
  end

  test "contains no credential kind" do
    refute :kind in RepoCredential.__schema__(:fields)
  end

  test "redacts the token from inspected structs" do
    credential = build(:repo_credential, token: "never-print-this-token")

    refute inspect(credential) =~ "never-print-this-token"
  end

  defp valid_attrs do
    %{name: "GitHub", username: "git-user", token: "secret-token"}
  end
end
