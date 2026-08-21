defmodule RintoPMOWeb.V1.JobControllerTest do
  use RintoPMOWeb.ConnCase, async: true

  alias RintoPMO.Repo

  describe "GET /jobs/:id" do
    test "a job still in the queue says to keep waiting", %{conn: conn} do
      job = insert_job("available")

      conn = get(conn, ~p"/api/v1/jobs/#{job.id}")

      assert %{
               "id" => id,
               "worker" => "RintoPMO.Tasks.EstimationWorker",
               "status" => "running",
               "error" => nil
             } = json_response(conn, 200)["data"]

      assert id == job.id
    end

    test "a job that is executing is still running", %{conn: conn} do
      job = insert_job("executing")

      assert %{"status" => "running"} =
               conn |> get(~p"/api/v1/jobs/#{job.id}") |> json_response(200) |> Map.get("data")
    end

    test "a completed job is a succeeded one", %{conn: conn} do
      job = insert_job("completed")

      assert %{"status" => "succeeded"} =
               conn |> get(~p"/api/v1/jobs/#{job.id}") |> json_response(200) |> Map.get("data")
    end

    # Which is what an estimation whose model call failed comes out as: it
    # returns `{:cancel, reason}` rather than raising.
    test "a cancelled job is a failed one, carrying what it said", %{conn: conn} do
      job =
        insert_job("cancelled", [
          %{
            "at" => "2026-08-22T09:00:00.000000Z",
            "attempt" => 1,
            "error" =>
              "** (Oban.PerformError) RintoPMO.Tasks.EstimationWorker failed with " <>
                "{:cancel, \"the model stopped responding\"}"
          }
        ])

      assert %{"status" => "failed", "error" => error} =
               conn |> get(~p"/api/v1/jobs/#{job.id}") |> json_response(200) |> Map.get("data")

      assert error =~ "the model stopped responding"
    end

    # Pruning only ever reaches jobs that are over, so this is not an error the
    # client has to handle -- it means stop waiting and re-read the task.
    test "a job that has been pruned away is a 404", %{conn: conn} do
      conn = get(conn, ~p"/api/v1/jobs/999999999")

      assert %{"error" => "not_found"} = json_response(conn, 404)
    end

    test "something that is not a job id is a 404 rather than a crash", %{conn: conn} do
      conn = get(conn, ~p"/api/v1/jobs/not-a-number")

      assert %{"error" => "not_found"} = json_response(conn, 404)
    end

    # Nothing a worker put in `args` comes back out: this endpoint answers
    # "keep waiting?" and nothing else.
    test "does not echo the job's arguments", %{conn: conn} do
      job = insert_job("available")

      data = conn |> get(~p"/api/v1/jobs/#{job.id}") |> json_response(200) |> Map.get("data")

      refute Map.has_key?(data, "args")
      refute Map.has_key?(data, "meta")
    end
  end

  defp insert_job(state, errors \\ []) do
    Repo.insert!(%Oban.Job{
      worker: "RintoPMO.Tasks.EstimationWorker",
      queue: "default",
      args: %{"task_id" => UUIDv7.generate(), "kind" => "difficulty"},
      state: state,
      errors: errors
    })
  end
end
