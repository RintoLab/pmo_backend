defmodule RintoPMO.Projects.ProjectRepoTest do
  use RintoPMO.DataCase, async: true

  alias RintoPMO.Projects.ProjectRepo

  describe "changeset/2" do
    test "accepts repository configuration" do
      project_repo = build(:project_repo)
      changeset = ProjectRepo.changeset(project_repo, valid_attrs())

      assert changeset.valid?
    end

    test "requires a name and a git URL" do
      for field <- [:name, :git_url] do
        changeset =
          %ProjectRepo{}
          |> ProjectRepo.changeset(Map.delete(valid_attrs(), field))

        refute changeset.valid?
        assert "can't be blank" in errors_on(changeset)[field]
      end
    end

    # Which branch to read belongs to the question, not to the registration.
    # `RintoPMO.Workspace` says why.
    test "holds no branch, and ignores one that is sent" do
      refute Map.has_key?(%ProjectRepo{}, :branch)

      changeset = ProjectRepo.changeset(%ProjectRepo{}, Map.put(valid_attrs(), :branch, "main"))

      assert changeset.valid?
      refute Map.has_key?(changeset.changes, :branch)
    end

    test "does not cast project ownership or synchronization results" do
      project_repo = insert(:project_repo)
      other_project = insert(:project)

      changeset =
        ProjectRepo.changeset(project_repo, %{
          project_id: other_project.id,
          last_synced_at: DateTime.utc_now(),
          last_sync_error: "hidden",
          name: "repo",
          git_url: "https://example.com/repo.git"
        })

      assert changeset.valid?
      assert Ecto.Changeset.get_field(changeset, :project_id) == project_repo.project_id
      assert Ecto.Changeset.get_field(changeset, :last_synced_at) == nil
      assert Ecto.Changeset.get_field(changeset, :last_sync_error) == nil
    end

    test "requires git_url to be a valid URI" do
      changeset =
        ProjectRepo.changeset(%ProjectRepo{}, Map.put(valid_attrs(), :git_url, "not a url"))

      refute changeset.valid?
      assert "must be a valid URI" in errors_on(changeset).git_url
    end

    test "requires HTTPS git_url when credential_id is set" do
      credential = insert(:repo_credential)

      changeset =
        ProjectRepo.changeset(
          %ProjectRepo{},
          valid_attrs()
          |> Map.put(:git_url, "http://example.com/owner/backend.git")
          |> Map.put(:credential_id, credential.id)
        )

      refute changeset.valid?
      assert "must use HTTPS when credential_id is set" in errors_on(changeset).git_url

      https_changeset =
        ProjectRepo.changeset(
          %ProjectRepo{},
          valid_attrs()
          |> Map.put(:git_url, "https://example.com/owner/backend.git")
          |> Map.put(:credential_id, credential.id)
        )

      assert https_changeset.valid?
    end
  end

  describe "suggest_name/1" do
    test "is the last segment of the URL, without .git" do
      assert ProjectRepo.suggest_name("https://github.com/acme/rinto.git") == "rinto"
      assert ProjectRepo.suggest_name("https://github.com/acme/rinto") == "rinto"
      assert ProjectRepo.suggest_name("ssh://git@host/~acme/rinto.git") == "rinto"
    end

    test "sanitises what it finds into a usable name" do
      assert ProjectRepo.suggest_name("https://host/acme/my repo.git") == "my-repo"
      assert ProjectRepo.suggest_name("https://host/acme/.hidden.git") == "hidden"
      assert ProjectRepo.suggest_name("https://host/acme/-x.git") == "x"
    end

    test "falls back rather than returning something uninsertable" do
      assert ProjectRepo.suggest_name("https://host/") == "repo"
      assert ProjectRepo.suggest_name("https://host/.git") == "repo"
      assert ProjectRepo.suggest_name(nil) == "repo"
    end

    test "always produces a name the changeset accepts" do
      for url <- [
            "https://github.com/acme/rinto.git",
            "https://host/acme/my repo.git",
            "https://host/acme/-x.git",
            "https://host/",
            "https://host/#{String.duplicate("a", 300)}.git"
          ] do
        attrs = %{name: ProjectRepo.suggest_name(url), git_url: "https://example.com/x.git"}

        assert ProjectRepo.changeset(%ProjectRepo{}, attrs).valid?,
               "#{url} suggested a name the changeset rejects"
      end
    end
  end

  defp valid_attrs do
    %{
      name: "backend",
      git_url: "https://example.com/owner/backend.git"
    }
  end
end
