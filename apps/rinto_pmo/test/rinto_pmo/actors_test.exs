defmodule RintoPMO.ActorsTest do
  # Not async: the configured token is application configuration, which is
  # global, and these tests change it.
  use RintoPMO.DataCase, async: false

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

  describe "authentication" do
    setup do
      configure_token("the-configured-token")
    end

    test "answers with the person this installation belongs to" do
      {:ok, human} = Actors.create_actor(%{kind: :human, name: "User"})

      assert {:ok, found} = Actors.authenticate("the-configured-token")
      assert found.id == human.id
    end

    test "refuses a token that is not the configured one" do
      {:ok, _human} = Actors.create_actor(%{kind: :human, name: "User"})

      assert Actors.authenticate("the-configured-toke") == {:error, :unauthorized}
      assert Actors.authenticate("the-configured-tokens") == {:error, :unauthorized}
      assert Actors.authenticate("") == {:error, :unauthorized}
      assert Actors.authenticate(nil) == {:error, :unauthorized}
      assert Actors.authenticate(42) == {:error, :unauthorized}
    end

    # A server with nothing to compare against is not a server with an open
    # door. It is told apart from a wrong token so that the operator who forgot
    # the variable is not sent looking for a client bug.
    test "refuses everything when the server was given no token" do
      {:ok, _human} = Actors.create_actor(%{kind: :human, name: "User"})
      configure_token(nil)

      assert Actors.authenticate("the-configured-token") == {:error, :token_not_configured}
      assert Actors.authenticate(nil) == {:error, :token_not_configured}
    end

    test "treats a blank configured token as none at all" do
      {:ok, _human} = Actors.create_actor(%{kind: :human, name: "User"})
      configure_token("   ")

      assert Actors.authenticate("   ") == {:error, :token_not_configured}
    end

    # The token says a request may be answered; it does not say who by, and
    # without a human there is nobody to attribute the write to.
    test "reports a database with nobody in it" do
      {:ok, _ai} = Actors.create_actor(valid_ai_attrs("Assistant"))

      assert Actors.authenticate("the-configured-token") == {:error, :human_actor_missing}
    end

    test "an AI is never who a request is answered as" do
      {:ok, _ai} = Actors.create_actor(valid_ai_attrs("Assistant"))
      {:ok, human} = Actors.create_actor(%{kind: :human, name: "User"})

      assert {:ok, found} = Actors.authenticate("the-configured-token")
      assert found.id == human.id
    end
  end

  describe "get_owner/0" do
    test "is the earliest human, whatever has been created since" do
      {:ok, first} = Actors.create_actor(%{kind: :human, name: "First"})
      {:ok, _second} = Actors.create_actor(%{kind: :human, name: "Second"})
      {:ok, _ai} = Actors.create_actor(valid_ai_attrs("Assistant"))

      assert %Actor{id: id} = Actors.get_owner()
      assert id == first.id
    end

    test "is nobody before there is a human" do
      {:ok, _ai} = Actors.create_actor(valid_ai_attrs("Assistant"))

      assert is_nil(Actors.get_owner())
    end
  end

  describe "configured_token/0" do
    test "is what the server was configured with" do
      configure_token("  padded  ")

      assert Actors.configured_token() == "padded"
    end

    test "is nothing when the server was configured with nothing" do
      configure_token(nil)

      assert is_nil(Actors.configured_token())
    end
  end

  defp configure_token(token) do
    previous = Application.get_env(:rinto_pmo, Actors)

    Application.put_env(:rinto_pmo, Actors, token: token)
    on_exit(fn -> Application.put_env(:rinto_pmo, Actors, previous) end)

    :ok
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
