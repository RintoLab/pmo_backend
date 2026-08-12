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

  describe "tokens" do
    test "issues a token and answers with the person holding it" do
      {:ok, human} = Actors.create_actor(%{kind: :human, name: "User"})

      assert {:ok, %Actor{token: token} = issued} = Actors.issue_token(human)
      assert is_binary(token)
      assert {:ok, found} = Actors.authenticate(token)
      assert found.id == issued.id
    end

    # A token somebody can choose is a token somebody eventually chooses badly,
    # and this is the whole of authentication.
    test "there is no way to supply one" do
      refute function_exported?(Actors, :put_token, 2)
      assert {:ok, human} = Actors.create_actor(%{kind: :human, name: "User"})
      assert {:ok, %Actor{token: token}} = Actors.issue_token(human)
      # 32 random bytes, URL-safe and unpadded.
      assert String.length(token) == 43
    end

    test "the previous token stops working the moment a new one is issued" do
      {:ok, human} = Actors.create_actor(%{kind: :human, name: "User"})
      {:ok, %{token: first}} = Actors.issue_token(human)
      {:ok, %{token: second}} = Actors.issue_token(human)

      assert first != second
      assert Actors.authenticate(first) == {:error, :unauthorized}
      assert {:ok, _found} = Actors.authenticate(second)
    end

    test "refuses a token nobody holds" do
      {:ok, human} = Actors.create_actor(%{kind: :human, name: "User"})
      {:ok, _issued} = Actors.issue_token(human)

      assert Actors.authenticate(Actors.generate_token()) == {:error, :unauthorized}
      assert Actors.authenticate(nil) == {:error, :unauthorized}
      assert Actors.authenticate(42) == {:error, :unauthorized}
    end

    # Told apart from a wrong token so that a fresh installation says what to
    # run instead of looking like a client bug.
    test "reports a system that has issued none at all" do
      {:ok, _human} = Actors.create_actor(%{kind: :human, name: "User"})

      assert Actors.authenticate("anything") == {:error, :token_not_configured}
      assert Actors.authenticate(nil) == {:error, :token_not_configured}
    end

    test "will not issue one to an AI" do
      {:ok, ai} = Actors.create_actor(valid_ai_attrs("Assistant"))

      assert {:error, changeset} = Actors.issue_token(ai)
      assert %{token: ["belongs to a human"]} = errors_on(changeset)
    end

    # Unreachable through `issue_token/1`, which generates. Asserted at the
    # constraint, because that is what has to hold once this system stops
    # assuming there is only one person in it.
    test "two actors cannot share a token" do
      {:ok, first} = Actors.create_actor(%{kind: :human, name: "First"})
      {:ok, second} = Actors.create_actor(%{kind: :human, name: "Second"})
      {:ok, issued} = Actors.issue_token(first)

      assert {:error, changeset} =
               second |> Actor.token_changeset(issued.token) |> RintoPMO.Repo.update()

      assert %{token: [_taken]} = errors_on(changeset)
    end

    test "the token is not part of what an actor update can write" do
      {:ok, human} = Actors.create_actor(%{kind: :human, name: "User"})
      {:ok, issued} = Actors.issue_token(human)

      assert {:ok, updated} = Actors.update_actor(issued, %{name: "Renamed", token: "smuggled"})
      assert updated.name == "Renamed"
      assert updated.token == issued.token
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
