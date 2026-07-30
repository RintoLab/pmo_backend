defmodule RintoPMO.Projects.ProjectRepoTest do
  use RintoPMO.DataCase, async: true

  alias RintoPMO.Projects.ProjectRepo

  describe "changeset/2" do
    test "accepts repository configuration" do
      project_repo = build(:project_repo)
      changeset = ProjectRepo.changeset(project_repo, valid_attrs())

      assert changeset.valid?
    end

    test "requires name, git URL, and branch" do
      for field <- [:name, :git_url, :branch] do
        changeset =
          %ProjectRepo{}
          |> ProjectRepo.changeset(Map.delete(valid_attrs(), field))

        refute changeset.valid?
        assert "can't be blank" in errors_on(changeset)[field]
      end
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
          git_url: "https://example.com/repo.git",
          branch: "main"
        })

      assert changeset.valid?
      assert Ecto.Changeset.get_field(changeset, :project_id) == project_repo.project_id
      assert Ecto.Changeset.get_field(changeset, :last_synced_at) == nil
      assert Ecto.Changeset.get_field(changeset, :last_sync_error) == nil
    end
  end

  defp valid_attrs do
    %{
      name: "backend",
      git_url: "https://example.com/owner/backend.git",
      branch: "main"
    }
  end
end
