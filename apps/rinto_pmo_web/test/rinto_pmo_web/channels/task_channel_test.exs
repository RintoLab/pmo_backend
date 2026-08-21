defmodule RintoPMOWeb.TaskChannelTest do
  use RintoPMOWeb.ChannelCase, async: true

  alias RintoPMO.Tasks
  alias RintoPMO.Tasks.Notifier
  alias RintoPMO.TasksMock

  setup do
    # The real context: these tests are about what the channel does with a
    # task, and mocking the thing being read would only test the mock.
    stub_with(TasksMock, Tasks)
    :ok
  end

  # A join is a subscription and only that. There is no attempt row to hand
  # back: a client either holds a job id and is waiting for its result, or it
  # holds nothing and is waiting for nothing.
  test "joining pushes nothing", %{socket: socket} do
    task = insert(:task)

    assert {:ok, _reply, _socket} = subscribe_and_join(socket, "task:#{task.id}")
    refute_push _event, _payload
  end

  test "joining a task that is not there is refused", %{socket: socket} do
    assert {:error, %{reason: "not_found"}} =
             subscribe_and_join(socket, "task:#{UUIDv7.generate()}")
  end

  test "pushes the outcome when an estimation finishes", %{socket: socket} do
    task = insert(:task)
    {:ok, _reply, _socket} = subscribe_and_join(socket, "task:#{task.id}")

    :ok = Notifier.broadcast_estimation(41, task.id, :difficulty, :succeeded, nil)

    assert_push "estimation", payload
    assert payload == %{job_id: 41, kind: :difficulty, status: :succeeded, error: nil}
  end

  test "a failure arrives with the words the provider used", %{socket: socket} do
    task = insert(:task)
    {:ok, _reply, _socket} = subscribe_and_join(socket, "task:#{task.id}")

    :ok =
      Notifier.broadcast_estimation(42, task.id, :time, :failed, "the model stopped responding")

    assert_push "estimation", %{status: :failed, kind: :time, error: error}
    assert error == "the model stopped responding"
  end

  # Two questions on one task, so one subscription hears both and `kind` says
  # which one stopped spinning.
  test "both kinds arrive on the same event", %{socket: socket} do
    task = insert(:task)
    {:ok, _reply, _socket} = subscribe_and_join(socket, "task:#{task.id}")

    :ok = Notifier.broadcast_estimation(1, task.id, :difficulty, :succeeded, nil)
    :ok = Notifier.broadcast_estimation(2, task.id, :time, :succeeded, nil)

    assert_push "estimation", %{kind: :difficulty}
    assert_push "estimation", %{kind: :time}
  end

  # Two tabs on the same task both hear it, which is the reason this is
  # broadcast on the task rather than pushed to whoever asked.
  test "reaches every connection watching the task" do
    task = insert(:task)

    {:ok, _reply, _first} = subscribe_and_join(connect_as(), "task:#{task.id}")
    {:ok, _reply, _second} = subscribe_and_join(connect_as(), "task:#{task.id}")

    :ok = Notifier.broadcast_estimation(7, task.id, :difficulty, :succeeded, nil)

    assert_push "estimation", %{job_id: 7}
    assert_push "estimation", %{job_id: 7}
  end
end
