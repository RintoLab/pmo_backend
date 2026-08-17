defmodule RintoPMO.Actors.ActorTest do
  use RintoPMO.DataCase, async: true

  alias RintoPMO.Actors.Actor

  describe "changeset/2" do
    test "accepts a human actor" do
      changeset =
        Actor.changeset(%{
          kind: :human,
          name: "Human",
          description: "Human participant",
          enabled: true
        })

      assert changeset.valid?
    end

    test "does not cast AI configuration for a human actor" do
      changeset =
        Actor.changeset(%{
          kind: :human,
          name: "Human",
          provider: "provider",
          model: "model",
          thinking_level: "low",
          system_prompt: "prompt",
          injection_profile: %{"profile" => "custom"}
        })

      assert changeset.valid?

      for field <- [:provider, :model, :thinking_level, :system_prompt, :injection_profile] do
        assert Ecto.Changeset.get_field(changeset, field) == nil
      end
    end

    test "accepts an AI actor with its required configuration" do
      changeset = Actor.changeset(valid_ai_attrs())

      assert changeset.valid?
      assert Ecto.Changeset.get_field(changeset, :provider) == "provider"
      assert Ecto.Changeset.get_field(changeset, :model) == "model"
      assert Ecto.Changeset.get_field(changeset, :thinking_level) == "high"
    end

    test "requires kind and name for every actor" do
      for {field, attrs} <- [
            kind: %{name: "Actor"},
            name: %{kind: :human}
          ] do
        changeset = Actor.changeset(attrs)

        refute changeset.valid?
        assert "can't be blank" in errors_on(changeset, field)
      end
    end

    test "rejects an explicitly empty enabled value" do
      changeset = Actor.changeset(%{kind: :human, name: "Human", enabled: nil})

      refute changeset.valid?
      assert "can't be blank" in errors_on(changeset, :enabled)
    end

    test "requires provider, model, and thinking level for an AI actor" do
      for field <- [:provider, :model, :thinking_level] do
        attrs = Map.delete(valid_ai_attrs(), field)
        changeset = Actor.changeset(attrs)

        refute changeset.valid?
        assert "can't be blank" in errors_on(changeset, field)
      end
    end

    test "rejects invalid kind values without raising" do
      invalid_kind = Actor.changeset(%{kind: :service, name: "Actor"})

      refute invalid_kind.valid?
      assert "is invalid" in errors_on(invalid_kind, :kind)
    end

    test "accepts arbitrary thinking level strings for AI actors" do
      changeset =
        Actor.changeset(%{valid_ai_attrs() | thinking_level: "provider-specific-level"})

      assert changeset.valid?
      assert Ecto.Changeset.get_field(changeset, :thinking_level) == "provider-specific-level"
    end

    test "does not allow changing kind from human to AI" do
      actor = build(:actor)
      changeset = Actor.changeset(actor, valid_ai_attrs())

      refute changeset.valid?
      assert "cannot change kind of actor" in errors_on(changeset, :kind)
    end

    test "does not allow changing kind from AI to human" do
      actor =
        build(:actor,
          kind: :ai,
          provider: "provider",
          model: "model",
          thinking_level: "high"
        )

      changeset = Actor.changeset(actor, %{kind: :human, name: "Human"})

      refute changeset.valid?
      assert "cannot change kind of actor" in errors_on(changeset, :kind)
    end

    test "allows updating an actor without changing kind" do
      actor =
        build(:actor,
          kind: :ai,
          provider: "provider",
          model: "model",
          thinking_level: "high"
        )

      changeset =
        Actor.changeset(actor, %{kind: :ai, name: "Updated AI", model: "new-model"})

      assert changeset.valid?
      assert Ecto.Changeset.get_field(changeset, :name) == "Updated AI"
      assert Ecto.Changeset.get_field(changeset, :model) == "new-model"
    end
  end

  test "is global and contains no project association" do
    refute :project_id in Actor.__schema__(:fields)
  end

  # An actor is a record of who somebody is, never of how they prove it. The
  # token is configuration on the server, which is what makes every field here
  # safe to render to anybody `GET /actors` answers.
  test "carries no credential at all" do
    fields = Actor.__schema__(:fields)

    refute :token in fields
    refute :password in fields
    refute :credential_id in fields
    refute :api_key in fields
  end

  defp valid_ai_attrs do
    %{
      kind: :ai,
      name: "Architect",
      provider: "provider",
      model: "model",
      thinking_level: "high",
      system_prompt: "Review architecture",
      injection_profile: %{"neighbor_blocks" => 3}
    }
  end

  defp errors_on(changeset, field) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {message, _opts} -> message end)
    |> Map.get(field, [])
  end
end
