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

    conn = post(conn, ~p"/api/v1/actors", actor: params)

    assert %{"id" => ^actor_id, "name" => "Human"} = json_response(conn, 201)["data"]
  end

  test "POST /api/v1/actors returns validation errors", %{conn: conn} do
    params = %{"kind" => "human"}
    changeset = Actor.changeset(params)

    expect(ActorsMock, :create_actor, fn ^params -> {:error, changeset} end)

    conn = post(conn, ~p"/api/v1/actors", actor: params)

    assert %{
             "status" => 422,
             "code" => "validation_error",
             "errors" => %{"name" => ["can't be blank"]}
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

    conn = patch(conn, ~p"/api/v1/actors/#{actor.id}", actor: params)

    assert %{"id" => ^actor_id, "name" => "Updated Human"} =
             json_response(conn, 200)["data"]
  end
end
