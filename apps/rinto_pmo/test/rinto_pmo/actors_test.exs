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

    test "fetches the only human without confusing AI actors for users" do
      {:ok, human} = Actors.create_actor(%{kind: :human, name: "User"})
      {:ok, _ai} = Actors.create_actor(valid_ai_attrs("Assistant"))

      assert {:ok, ^human} = Actors.get_unique_human()
    end

    test "reports when there is no human" do
      {:ok, _ai} = Actors.create_actor(valid_ai_attrs("Assistant"))

      assert {:error, :human_actor_not_found} = Actors.get_unique_human()
    end

    test "refuses to choose between several humans" do
      {:ok, first} = Actors.create_actor(%{kind: :human, name: "First"})
      {:ok, second} = Actors.create_actor(%{kind: :human, name: "Second"})

      assert {:error, :human_actor_ambiguous, details} = Actors.get_unique_human()
      assert MapSet.new(details.actor_ids) == MapSet.new([first.id, second.id])
    end

    test "updates configuration and disables an actor" do
      {:ok, actor} = Actors.create_actor(valid_ai_attrs("AI"))

      assert {:ok, updated_actor} =
               Actors.update_actor(actor, %{model: "new-model", thinking_level: "high"})

      assert updated_actor.model == "new-model"
      assert updated_actor.thinking_level == "high"

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
      thinking_level: "high"
    }
  end
end
