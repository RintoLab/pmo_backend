defmodule Mix.Tasks.Rinto.Actors.SetupHumanTest do
  # Not async: the task writes to `Mix.shell()`, which is global.
  use RintoPMO.DataCase, async: false

  alias Mix.Tasks.Rinto.Actors.SetupHuman
  alias RintoPMO.Actors
  alias RintoPMO.Projects

  setup do
    previous = Mix.shell()
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(previous) end)
    :ok
  end

  test "creates the human actor and issues it a token" do
    run(["--name", "Kenton"])

    assert {:ok, human} = Actors.get_unique_human()
    assert human.name == "Kenton"
    assert {:ok, ^human} = Actors.authenticate(human.token)
    assert output() =~ human.token
  end

  # A document created without a project is filed here, so an installation
  # without it cannot take the most ordinary write there is.
  test "creates the default project" do
    run([])

    assert %{name: "Personal", slug: "personal"} = Projects.get_default_project()
  end

  test "leaves an existing default project alone" do
    {:ok, existing} =
      Projects.create_project(%{
        name: "Renamed by hand",
        slug: Projects.default_slug(),
        description: "Mine"
      })

    run([])

    assert %{id: id, name: "Renamed by hand"} = Projects.get_default_project()
    assert id == existing.id
  end

  # The tie is a question about identity, and should not also leave the system
  # with nowhere to put documents.
  test "creates the default project even when it cannot choose a person" do
    {:ok, _first} = Actors.create_actor(%{kind: :human, name: "First"})
    {:ok, _second} = Actors.create_actor(%{kind: :human, name: "Second"})

    assert_raise Mix.Error, fn -> run([]) end

    assert %{slug: "personal"} = Projects.get_default_project()
  end

  # The usual reason to run this a second time is having closed the terminal
  # the token was printed in. Rotating then would log out the editor and the
  # CLI to solve a problem neither of them had.
  test "running it again prints the same token rather than replacing it" do
    run([])
    {:ok, first} = Actors.get_unique_human()

    run([])

    assert {:ok, again} = Actors.get_unique_human()
    assert again.id == first.id
    assert again.token == first.token
    assert output() =~ first.token
  end

  test "--rotate replaces the token" do
    run([])
    {:ok, first} = Actors.get_unique_human()

    run(["--rotate"])

    assert {:ok, rotated} = Actors.get_unique_human()
    assert rotated.id == first.id
    assert rotated.token != first.token
    assert Actors.authenticate(first.token) == {:error, :unauthorized}
  end

  test "adopts a human that exists but has no token" do
    {:ok, existing} = Actors.create_actor(%{kind: :human, name: "Already Here"})

    run([])

    assert {:ok, adopted} = Actors.get_unique_human()
    assert adopted.id == existing.id
    assert {:ok, _found} = Actors.authenticate(adopted.token)
  end

  # Issuing to the wrong one would attribute a person's decisions to somebody
  # else, so it names the candidates and stops.
  test "refuses to choose between two people" do
    {:ok, first} = Actors.create_actor(%{kind: :human, name: "First"})
    {:ok, second} = Actors.create_actor(%{kind: :human, name: "Second"})

    assert_raise Mix.Error, fn -> run([]) end

    assert is_nil(RintoPMO.Repo.reload!(first).token)
    assert is_nil(RintoPMO.Repo.reload!(second).token)
  end

  # The only way out of that tie: the API endpoint cannot help, because it
  # needs the token being asked for.
  test "--actor-id answers the tie" do
    {:ok, first} = Actors.create_actor(%{kind: :human, name: "First"})
    {:ok, second} = Actors.create_actor(%{kind: :human, name: "Second"})

    run(["--actor-id", second.id])

    assert is_nil(RintoPMO.Repo.reload!(first).token)
    assert {:ok, chosen} = Actors.authenticate(RintoPMO.Repo.reload!(second).token)
    assert chosen.id == second.id
  end

  test "--actor-id refuses an AI, whatever the tie looks like" do
    {:ok, ai} =
      Actors.create_actor(%{
        kind: :ai,
        name: "Architect",
        provider: "provider",
        model: "model",
        thinking_level: "high"
      })

    assert_raise Mix.Error, ~r/is an AI actor/, fn -> run(["--actor-id", ai.id]) end

    assert is_nil(RintoPMO.Repo.reload!(ai).token)
  end

  test "--actor-id reports an id that names nobody" do
    assert_raise Mix.Error, ~r/no actor with id/, fn ->
      run(["--actor-id", UUIDv7.generate()])
    end
  end

  # `Mix.Task.run("app.start")` is a no-op under the test runner, so calling
  # `run/1` twice would otherwise be skipped as already-run.
  defp run(argv) do
    Mix.Task.reenable("rinto.actors.setup_human")
    SetupHuman.run(argv)
  end

  defp output do
    receive do
      {:mix_shell, :info, [message]} -> message <> output()
    after
      0 -> ""
    end
  end
end
