defmodule RintoPMOWeb.V1.SettingControllerTest do
  use RintoPMOWeb.ConnCase, async: true

  @empty_settings %{
    "title_actor" => nil,
    "decomposition_actor" => nil,
    "estimation_actor" => nil,
    "annotation_actor" => nil
  }

  test "GET settings answers with every role, filled or not", %{conn: conn} do
    conn = get(conn, ~p"/api/v1/settings")

    assert json_response(conn, 200)["data"] == @empty_settings
  end

  test "PUT settings/:key puts an actor in the role", %{conn: conn} do
    actor = ai_actor()
    actor_id = actor.id

    conn = put(conn, ~p"/api/v1/settings/title_actor", %{"actor_id" => actor.id})

    # The actor whole, not an id: the question this endpoint answers is "who is
    # naming my topics", and that should not need a second request.
    assert %{"title_actor" => %{"id" => ^actor_id, "model" => "gemini-flash"}} =
             json_response(conn, 200)["data"]
  end

  test "PUT settings/:key with null empties the role", %{conn: conn} do
    actor = ai_actor()
    put(conn, ~p"/api/v1/settings/title_actor", %{"actor_id" => actor.id})

    conn = put(conn, ~p"/api/v1/settings/title_actor", %{"actor_id" => nil})

    assert json_response(conn, 200)["data"] == @empty_settings
  end

  test "PUT settings/:key refuses an actor with no model to ask", %{conn: conn} do
    human = insert(:actor, kind: :human)

    conn = put(conn, ~p"/api/v1/settings/title_actor", %{"actor_id" => human.id})

    assert %{"error" => "validation_error", "details" => %{"actor_id" => [message]}} =
             json_response(conn, 422)

    assert message == "must be an AI actor"
  end

  test "PUT settings/:key on a role that does not exist is a 404", %{conn: conn} do
    actor = ai_actor()

    conn = put(conn, ~p"/api/v1/settings/chief_of_vibes", %{"actor_id" => actor.id})

    assert %{"error" => "not_found"} = json_response(conn, 404)
  end

  defp ai_actor do
    insert(:actor,
      kind: :ai,
      provider: "google",
      model: "gemini-flash",
      thinking_level: "off"
    )
  end
end
