defmodule RintoPMOWeb.V1.AIRoleControllerTest do
  use RintoPMOWeb.ConnCase, async: true

  @empty %{"topic_naming" => nil, "task_estimation" => nil}

  @configuration %{
    "provider" => "google",
    "model" => "gemini-flash",
    "thinking_level" => "off",
    "system_prompt" => "Lead with the subsystem."
  }

  test "GET ai_roles answers with every job, configured or not", %{conn: conn} do
    conn = get(conn, ~p"/api/v1/ai_roles")

    assert json_response(conn, 200)["data"] == @empty
  end

  test "PUT ai_roles/:key configures the job", %{conn: conn} do
    conn = put(conn, ~p"/api/v1/ai_roles/topic_naming", @configuration)

    assert %{"topic_naming" => role, "task_estimation" => nil} = json_response(conn, 200)["data"]

    assert role["provider"] == "google"
    assert role["model"] == "gemini-flash"
    assert role["thinking_level"] == "off"
    assert role["system_prompt"] == "Lead with the subsystem."
  end

  # A `PUT` writes the row whole: a body without `system_prompt` is somebody
  # emptying the textarea, not somebody who forgot to send it.
  test "PUT ai_roles/:key clears a standing instruction left out of the body", %{conn: conn} do
    put(conn, ~p"/api/v1/ai_roles/topic_naming", @configuration)

    conn =
      put(conn, ~p"/api/v1/ai_roles/topic_naming", Map.delete(@configuration, "system_prompt"))

    assert json_response(conn, 200)["data"]["topic_naming"]["system_prompt"] == nil
  end

  test "PUT ai_roles/:key refuses a model configuration with a hole in it", %{conn: conn} do
    conn = put(conn, ~p"/api/v1/ai_roles/topic_naming", %{"provider" => "google"})

    assert %{"error" => "validation_error", "details" => details} = json_response(conn, 422)
    assert details["model"] == ["can't be blank"]
    assert details["thinking_level"] == ["can't be blank"]
  end

  # Not a bad body -- there is no such job to write to, and no `POST` that
  # could make one.
  test "PUT ai_roles/:key on a job that does not exist is a 404", %{conn: conn} do
    conn = put(conn, ~p"/api/v1/ai_roles/chief_of_vibes", @configuration)

    assert %{"error" => "not_found"} = json_response(conn, 404)
  end

  test "DELETE ai_roles/:key empties the job and answers with the set", %{conn: conn} do
    put(conn, ~p"/api/v1/ai_roles/task_estimation", @configuration)

    conn = delete(conn, ~p"/api/v1/ai_roles/task_estimation")

    assert json_response(conn, 200)["data"] == @empty
  end

  test "DELETE ai_roles/:key on a job nobody configured succeeds", %{conn: conn} do
    conn = delete(conn, ~p"/api/v1/ai_roles/topic_naming")

    assert json_response(conn, 200)["data"] == @empty
  end

  test "DELETE ai_roles/:key on a job that does not exist is a 404", %{conn: conn} do
    conn = delete(conn, ~p"/api/v1/ai_roles/chief_of_vibes")

    assert %{"error" => "not_found"} = json_response(conn, 404)
  end
end
