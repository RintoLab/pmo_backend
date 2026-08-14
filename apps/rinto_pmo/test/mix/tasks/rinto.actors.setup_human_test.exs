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

  test "creates the human actor" do
    run(["--name", "Kenton"])

    assert {:ok, human} = Actors.get_unique_human()
    assert human.name == "Kenton"
  end

  # The token is agreed in advance and configured on both ends, so this task
  # has none to invent and none to print.
  test "issues nothing and prints no token" do
    run(["--name", "Kenton"])

    refute output() =~ Actors.configured_token()
  end

  test "says where the token comes from when the server has none" do
    previous = Application.get_env(:rinto_pmo, Actors)
    Application.put_env(:rinto_pmo, Actors, token: nil)
    on_exit(fn -> Application.put_env(:rinto_pmo, Actors, previous) end)

    run([])

    assert output() =~ "RINTO_TOKEN"
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

  test "running it again changes nothing" do
    run([])
    {:ok, first} = Actors.get_unique_human()

    run([])

    assert {:ok, again} = Actors.get_unique_human()
    assert again.id == first.id
    assert length(Actors.list_actors()) == 1
  end

  test "adopts a human that is already there" do
    {:ok, existing} = Actors.create_actor(%{kind: :human, name: "Already Here"})

    run([])

    assert {:ok, adopted} = Actors.get_unique_human()
    assert adopted.id == existing.id
  end

  # There is a single token, so there is a single caller, and nothing here for
  # a tie to be between. It says which of them requests are answered as.
  test "names the owner rather than refusing when there are several humans" do
    {:ok, first} = Actors.create_actor(%{kind: :human, name: "First"})
    {:ok, _second} = Actors.create_actor(%{kind: :human, name: "Second"})

    run([])

    printed = output()
    assert printed =~ "2 human actors"
    assert printed =~ first.id
  end

  test "creates no third human when there are already two" do
    {:ok, _first} = Actors.create_actor(%{kind: :human, name: "First"})
    {:ok, _second} = Actors.create_actor(%{kind: :human, name: "Second"})

    run([])

    assert length(Actors.list_actors()) == 2
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
