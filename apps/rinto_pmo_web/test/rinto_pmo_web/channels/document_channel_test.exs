defmodule RintoPMOWeb.DocumentChannelTest do
  use RintoPMOWeb.ChannelCase, async: true

  alias RintoPMO.Documents
  alias RintoPMO.Documents.Decomposition
  alias RintoPMO.Documents.Notifier
  alias RintoPMO.DocumentsMock
  alias RintoPMO.Projects
  alias RintoPMO.ProjectsMock

  setup do
    # The real context: these tests are about what the channel does with a
    # document, and mocking the thing being read would only test the mock.
    stub_with(DocumentsMock, Documents)
    # A document created without a project is filed in the default one, which
    # therefore has to exist and has to be findable.
    stub_with(ProjectsMock, Projects)
    insert(:default_project)
    :ok
  end

  test "joining answers with the most recent attempt, or null", %{socket: socket} do
    document = document()

    assert {:ok, _reply, _socket} = subscribe_and_join(socket, "document:#{document.id}")
    assert_push "decomposition", %{decomposition: nil}
  end

  test "joining a document that is not there is refused", %{socket: socket} do
    assert {:error, %{reason: "not_found"}} =
             subscribe_and_join(socket, "document:#{UUIDv7.generate()}")
  end

  test "pushes the attempt's row every time it moves", %{socket: socket} do
    document = document()
    {:ok, _reply, _socket} = subscribe_and_join(socket, "document:#{document.id}")
    assert_push "decomposition", %{decomposition: nil}

    attempt = attempt(document, :running)
    :ok = Notifier.broadcast_decomposition(attempt)

    assert_push "decomposition", %{decomposition: %{status: :running, id: id}}
    assert id == attempt.id
  end

  # Pieces of a stream, not lines and not whole messages: the client appends
  # them in order and a chunk may end mid-word.
  test "passes on the model's output as it arrives", %{socket: socket} do
    document = document()
    {:ok, _reply, _socket} = subscribe_and_join(socket, "document:#{document.id}")
    assert_push "decomposition", %{decomposition: nil}

    attempt = attempt(document, :running)
    :ok = Notifier.broadcast_output(attempt, "## Can")
    :ok = Notifier.broadcast_output(attempt, "ary\n")

    assert_push "decomposition_output", %{chunk: "## Can", decomposition_id: id}
    assert id == attempt.id
    assert_push "decomposition_output", %{chunk: "ary\n"}
  end

  # Two tabs on the same document both watch it, which is the reason this is
  # broadcast on the document rather than pushed to whoever asked.
  test "reaches every connection watching the document" do
    document = document()

    {:ok, _reply, _first} = subscribe_and_join(connect_as(), "document:#{document.id}")
    {:ok, _reply, _second} = subscribe_and_join(connect_as(), "document:#{document.id}")

    assert_push "decomposition", %{decomposition: nil}
    assert_push "decomposition", %{decomposition: nil}

    :ok = Notifier.broadcast_output(attempt(document, :running), "text")

    assert_push "decomposition_output", %{chunk: "text"}
    assert_push "decomposition_output", %{chunk: "text"}
  end

  defp document do
    {:ok, document} = Documents.create_document(%{title: "Rollout plan"})
    document
  end

  # Built rather than run: this is about what the channel does with what it is
  # told, and running a decomposition would drag a model call in behind it.
  defp attempt(document, status) do
    %Decomposition{}
    |> Decomposition.creation_changeset(document.id)
    |> Ecto.Changeset.change(status: status)
    |> RintoPMO.Repo.insert!()
  end
end
