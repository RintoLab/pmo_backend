defmodule RintoPMO.Projects.ProjectTest do
  use RintoPMO.DataCase, async: true

  alias RintoPMO.Projects.Project

  describe "changeset/2" do
    test "accepts required project metadata and defaults to active" do
      changeset = Project.changeset(valid_attrs())

      assert changeset.valid?
      assert Ecto.Changeset.get_field(changeset, :status) == :active
    end

    test "requires name, slug, and description" do
      for field <- [:name, :slug, :description] do
        changeset = valid_attrs() |> Map.delete(field) |> Project.changeset()

        refute changeset.valid?
        assert "can't be blank" in errors_on(changeset)[field]
      end
    end

    test "validates a URL-safe slug" do
      changeset = Project.changeset(%{valid_attrs() | slug: "Not URL Safe"})

      refute changeset.valid?
      assert [_message] = errors_on(changeset).slug
    end

    test "does not allow attrs to set status" do
      changeset = Project.changeset(Map.put(valid_attrs(), :status, :archived))

      assert changeset.valid?
      assert Ecto.Changeset.get_field(changeset, :status) == :active
    end

    test "updates metadata but does not cast status" do
      project = build(:project, status: :active)

      changeset = Project.changeset(project, %{name: "Updated", status: :archived})

      assert changeset.valid?
      assert Ecto.Changeset.get_field(changeset, :name) == "Updated"
      assert Ecto.Changeset.get_field(changeset, :status) == :active
    end
  end

  test "archive_changeset/1 sets archived status" do
    project = build(:project, status: :active)
    changeset = Project.archive_changeset(project)

    assert changeset.valid?
    assert Ecto.Changeset.get_field(changeset, :status) == :archived
  end

  test "has an independent collection of project repositories" do
    assert %{cardinality: :many, related: RintoPMO.Projects.ProjectRepo} =
             Project.__schema__(:association, :repos)
  end

  test "does not contain a default agent field" do
    refute :default_agent_actor_id in Project.__schema__(:fields)
  end

  defp valid_attrs do
    %{name: "Rinto PMO", slug: "rinto-pmo", description: "Project management"}
  end
end
