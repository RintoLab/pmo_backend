defmodule RintoPMO.ActorsTest do
  use RintoPMO.DataCase, async: true

  alias RintoPMO.Actors
  alias RintoPMO.Actors.Actor

  describe "actors" do
    test "creates and fetches an actor" do
      assert {:ok, %Actor{} = actor} =
               Actors.create_actor(%{kind: :human, name: "Human", description: "User"})

      assert String.at(actor.id, 14) == "7"
      assert Actors.get_actor!(actor.id) == actor
      assert actor in Actors.list_actors()
    end

    test "lists all actors" do
      {:ok, first_actor} = Actors.create_actor(valid_ai_attrs("Architect"))
      {:ok, second_actor} = Actors.create_actor(valid_ai_attrs("Estimator"))

      returned_ids = Actors.list_actors() |> Enum.map(& &1.id) |> MapSet.new()

      assert returned_ids == MapSet.new([first_actor.id, second_actor.id])
    end

    test "updates configuration and disables an actor" do
      {:ok, actor} = Actors.create_actor(valid_ai_attrs("AI"))

      assert {:ok, updated_actor} =
               Actors.update_actor(actor, %{model: "new-model", thinking_level: :high})

      assert updated_actor.model == "new-model"
      assert updated_actor.thinking_level == :high

      assert {:ok, disabled_actor} = Actors.update_actor(updated_actor, %{enabled: false})
      refute disabled_actor.enabled
    end
  end

  defp valid_ai_attrs(name) do
    %{
      kind: :ai,
      name: name,
      provider: "provider",
      model: "model",
      thinking_level: :high
    }
  end
end
