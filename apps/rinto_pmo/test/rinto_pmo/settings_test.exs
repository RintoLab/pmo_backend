defmodule RintoPMO.SettingsTest do
  use RintoPMO.DataCase, async: true

  alias RintoPMO.Actors
  alias RintoPMO.Settings

  describe "list_settings/0" do
    test "answers with every role, empty ones included" do
      assert Settings.list_settings() == %{"title_actor" => nil}
    end

    test "carries the actor in each filled role" do
      actor = ai_actor()
      assert {:ok, _settings} = Settings.put_actor("title_actor", actor.id)

      assert %{"title_actor" => %{id: id}} = Settings.list_settings()
      assert id == actor.id
    end
  end

  describe "put_actor/2" do
    test "puts an actor in a role and hands back the whole set" do
      actor = ai_actor()

      assert {:ok, %{"title_actor" => chosen}} = Settings.put_actor("title_actor", actor.id)
      assert chosen.id == actor.id
      assert Settings.get_actor("title_actor").id == actor.id
    end

    test "replaces rather than accumulates" do
      first = ai_actor()
      second = ai_actor()

      assert {:ok, _settings} = Settings.put_actor("title_actor", first.id)
      assert {:ok, _settings} = Settings.put_actor("title_actor", second.id)

      assert Settings.get_actor("title_actor").id == second.id
    end

    test "empties a role with nil" do
      actor = ai_actor()
      assert {:ok, _settings} = Settings.put_actor("title_actor", actor.id)

      assert {:ok, %{"title_actor" => nil}} = Settings.put_actor("title_actor", nil)
      assert Settings.get_actor("title_actor") == nil
    end

    test "refuses a human: there is no model to ask" do
      human = insert(:actor, kind: :human)

      assert {:error, changeset} = Settings.put_actor("title_actor", human.id)
      assert %{actor_id: ["must be an AI actor"]} = errors_on(changeset)
    end

    test "refuses an actor that is turned off" do
      actor = ai_actor(enabled: false)

      assert {:error, changeset} = Settings.put_actor("title_actor", actor.id)
      assert %{actor_id: ["is disabled"]} = errors_on(changeset)
    end

    test "refuses an actor that is not there" do
      assert {:error, changeset} = Settings.put_actor("title_actor", UUIDv7.generate())
      assert %{actor_id: ["does not exist"]} = errors_on(changeset)

      assert {:error, changeset} = Settings.put_actor("title_actor", "not-a-uuid")
      assert %{actor_id: ["is invalid"]} = errors_on(changeset)
    end

    test "refuses a role the system does not have" do
      assert Settings.put_actor("chief_of_vibes", UUIDv7.generate()) == {:error, :not_found}
    end
  end

  describe "get_actor/1" do
    test "an empty role is nobody" do
      assert Settings.get_actor("title_actor") == nil
    end

    # Strict when chosen, lenient when read: turning an actor off must not stop
    # topics being named, it just stops them being named by that one.
    test "an actor turned off after being chosen is nobody" do
      actor = ai_actor()
      assert {:ok, _settings} = Settings.put_actor("title_actor", actor.id)

      assert {:ok, _disabled} = Actors.update_actor(actor, %{"enabled" => false})

      assert Settings.get_actor("title_actor") == nil
      assert Settings.list_settings() == %{"title_actor" => nil}
    end
  end

  defp ai_actor(attrs \\ []) do
    insert(
      :actor,
      Keyword.merge(
        [kind: :ai, provider: "google", model: "gemini-flash", thinking_level: "off"],
        attrs
      )
    )
  end
end
