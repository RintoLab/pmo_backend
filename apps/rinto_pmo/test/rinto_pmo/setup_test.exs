defmodule RintoPMO.SetupTest do
  use RintoPMO.DataCase, async: true

  alias RintoPMO.Actors
  alias RintoPMO.Actors.Actor
  alias RintoPMO.Projects
  alias RintoPMO.Projects.Project
  alias RintoPMO.Setup

  describe "ensure_default_project/0" do
    test "creates the reserved project" do
      assert {:created, %Project{name: "Personal", slug: "personal"}} =
               Setup.ensure_default_project()
    end

    test "adopts one that is already there, renamed or not" do
      {:ok, existing} =
        Projects.create_project(%{
          name: "Renamed by hand",
          slug: Projects.default_slug(),
          description: "Mine"
        })

      assert {:present, %Project{id: id}} = Setup.ensure_default_project()
      assert id == existing.id
    end
  end

  describe "ensure_default_assistant/0" do
    test "creates one AI with no model configuration" do
      assert {:created, :assistant, %Actor{kind: :ai, name: "AI"} = assistant} =
               Setup.ensure_default_assistant()

      assert assistant.default
      assert {assistant.provider, assistant.model, assistant.thinking_level} == {nil, nil, nil}
    end

    test "adopts the one already there, whatever it has been renamed to" do
      {:created, :assistant, first} = Setup.ensure_default_assistant()
      {:ok, _renamed} = Actors.update_actor(first, %{name: "Assistant"})

      assert {:present, :assistant, %Actor{id: id, name: "Assistant"}} =
               Setup.ensure_default_assistant()

      assert id == first.id
    end
  end

  describe "ensure_human/1" do
    test "creates the human with the name it is given" do
      assert {:created, %Actor{kind: :human, name: "Kenton"}} = Setup.ensure_human("Kenton")
    end

    test "names them after the account running the server when told nobody" do
      assert {:created, %Actor{name: name}} = Setup.ensure_human(nil)
      assert name == Setup.default_name()
    end

    test "adopts a human that is already there" do
      {:ok, existing} = Actors.create_actor(%{kind: :human, name: "Already Here"})

      assert {:present, %Actor{id: id}} = Setup.ensure_human("Ignored")
      assert id == existing.id
      assert length(Actors.list_actors()) == 1
    end

    # There is a single token, so there is a single caller, and nothing here to
    # break a tie between. It says which of them requests are answered as.
    test "reports several humans and names the one requests are answered as" do
      {:ok, first} = Actors.create_actor(%{kind: :human, name: "First"})
      {:ok, _second} = Actors.create_actor(%{kind: :human, name: "Second"})

      assert {:several, 2, %Actor{id: id}} = Setup.ensure_human(nil)
      assert id == first.id
      assert length(Actors.list_actors()) == 2
    end

    test "an AI is not somebody to answer as" do
      insert(:actor, kind: :ai, name: "Architect")

      assert {:created, %Actor{kind: :human}} = Setup.ensure_human("Kenton")
    end
  end

  # Both `mix rinto.actors.setup_human` and `RintoPMO.Release.setup_human/1`
  # print through this. Two entry points wording the same outcome differently
  # is how one of them ends up lying.
  describe "describe/1" do
    test "says what happened to the project" do
      assert Setup.ensure_default_project() |> Setup.describe() =~
               "created default project Personal (personal)"

      assert Setup.ensure_default_project() |> Setup.describe() =~
               "default project Personal (personal) is already there"
    end

    test "says what happened to the default assistant" do
      assert Setup.ensure_default_assistant() |> Setup.describe() =~
               "created default assistant AI"

      assert Setup.ensure_default_assistant() |> Setup.describe() =~
               "default assistant AI"

      assert Setup.ensure_default_assistant() |> Setup.describe() =~ "is already there"
    end

    test "says what happened to the human" do
      created = Setup.ensure_human("Kenton")

      assert Setup.describe(created) =~ "created human actor Kenton"
      assert Setup.describe(Setup.ensure_human(nil)) =~ "is already there"
    end

    test "names the owner when there are several" do
      {:ok, first} = Actors.create_actor(%{kind: :human, name: "First"})
      {:ok, _second} = Actors.create_actor(%{kind: :human, name: "Second"})

      described = Setup.ensure_human(nil) |> Setup.describe()

      assert described =~ "2 human actors"
      assert described =~ first.id
    end
  end
end
