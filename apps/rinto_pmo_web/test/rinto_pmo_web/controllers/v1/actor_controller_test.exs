defmodule RintoPMOWeb.V1.ActorControllerTest do
  use RintoPMOWeb.ConnCase, async: true

  alias RintoPMO.Actors.Actor
  alias RintoPMO.ActorsMock

  test "GET /api/v1/actors lists actors", %{conn: conn} do
    actor = insert(:actor, name: "Human")
    actor_id = actor.id

    expect(ActorsMock, :list_actors, fn -> [actor] end)

    conn = get(conn, ~p"/api/v1/actors")

    assert [%{"id" => ^actor_id, "name" => "Human", "kind" => "human"}] =
             json_response(conn, 200)["data"]
  end

  test "GET /api/v1/actors/human returns the system's only person", %{conn: conn} do
    human = insert(:actor, kind: :human, name: "User")
    human_id = human.id

    expect(ActorsMock, :get_unique_human, fn -> {:ok, human} end)

    conn = get(conn, ~p"/api/v1/actors/human")

    assert %{"id" => ^human_id, "kind" => "human", "name" => "User"} =
             json_response(conn, 200)["data"]
  end

  test "GET /api/v1/actors/human reports a missing person", %{conn: conn} do
    expect(ActorsMock, :get_unique_human, fn -> {:error, :human_actor_not_found} end)

    conn = get(conn, ~p"/api/v1/actors/human")

    assert %{"error" => "human_actor_not_found"} = json_response(conn, 404)
  end

  test "GET /api/v1/actors/human refuses an ambiguous identity", %{conn: conn} do
    ids = [UUIDv7.generate(), UUIDv7.generate()]

    expect(ActorsMock, :get_unique_human, fn ->
      {:error, :human_actor_ambiguous, %{actor_ids: ids}}
    end)

    conn = get(conn, ~p"/api/v1/actors/human")

    assert %{"error" => "human_actor_ambiguous", "details" => %{"actor_ids" => ^ids}} =
             json_response(conn, 409)
  end

  test "GET /api/v1/actors/:id shows an actor", %{conn: conn} do
    actor = insert(:actor, name: "Human")
    actor_id = actor.id

    expect(ActorsMock, :get_actor!, fn id ->
      assert id == actor.id
      actor
    end)

    conn = get(conn, ~p"/api/v1/actors/#{actor.id}")

    assert %{"id" => ^actor_id, "name" => "Human"} = json_response(conn, 200)["data"]
  end

  test "POST /api/v1/actors creates an actor", %{conn: conn} do
    actor = insert(:actor, name: "Human")
    actor_id = actor.id
    params = %{"kind" => "human", "name" => "Human"}

    expect(ActorsMock, :create_actor, fn ^params -> {:ok, actor} end)

    conn = post(conn, ~p"/api/v1/actors", params)

    assert %{"id" => ^actor_id, "name" => "Human"} = json_response(conn, 201)["data"]
  end

  test "POST /api/v1/actors returns validation errors", %{conn: conn} do
    params = %{"kind" => "human"}
    changeset = Actor.changeset(params)

    expect(ActorsMock, :create_actor, fn ^params -> {:error, changeset} end)

    conn = post(conn, ~p"/api/v1/actors", params)

    assert %{
             "error" => "validation_error",
             "message" => "Request validation failed.",
             "details" => %{"name" => ["can't be blank"]}
           } = json_response(conn, 422)
  end

  test "PATCH /api/v1/actors/:id updates an actor", %{conn: conn} do
    actor = insert(:actor, name: "Human")
    actor_id = actor.id
    updated_actor = %{actor | name: "Updated Human"}
    params = %{"name" => "Updated Human"}

    expect(ActorsMock, :get_actor!, fn id ->
      assert id == actor.id
      actor
    end)

    expect(ActorsMock, :update_actor, fn ^actor, ^params -> {:ok, updated_actor} end)

    conn = patch(conn, ~p"/api/v1/actors/#{actor.id}", params)

    assert %{"id" => ^actor_id, "name" => "Updated Human"} =
             json_response(conn, 200)["data"]
  end
end
