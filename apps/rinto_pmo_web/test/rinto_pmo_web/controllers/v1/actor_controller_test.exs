defmodule RintoPMOWeb.V1.ActorControllerTest do
  use RintoPMOWeb.ConnCase, async: true

  alias RintoPMO.Actors
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

  describe "GET /api/v1/actors/me" do
    test "answers with whoever the token belongs to", %{conn: conn, current_actor: actor} do
      actor_id = actor.id

      conn = get(conn, ~p"/api/v1/actors/me")

      assert %{"id" => ^actor_id, "kind" => "human"} = json_response(conn, 200)["data"]
    end

    # The token is a credential, and an identity payload that sometimes carries
    # one is a payload that ends up in a log.
    test "does not hand the token back", %{conn: conn} do
      conn = get(conn, ~p"/api/v1/actors/me")

      refute Map.has_key?(json_response(conn, 200)["data"], "token")
    end
  end

  describe "PUT /api/v1/actors/me/token" do
    test "issues a new token and returns it once", %{conn: conn, current_actor: actor} do
      conn = put(conn, ~p"/api/v1/actors/me/token")

      assert %{"token" => issued, "actor_id" => actor_id} = json_response(conn, 200)["data"]
      assert actor_id == actor.id
      assert issued != actor.token
      assert {:ok, _actor} = Actors.authenticate(issued)
    end

    test "the old token stops working", %{conn: conn, current_actor: actor} do
      assert %{"token" => _issued} =
               conn |> put(~p"/api/v1/actors/me/token") |> json_response(200) |> Map.get("data")

      assert Actors.authenticate(actor.token) == {:error, :unauthorized}
    end

    # A token somebody can choose is a token somebody eventually chooses badly,
    # and this one is the whole of authentication.
    test "ignores a token the caller tries to choose", %{conn: conn} do
      mine = String.duplicate("k", 40)

      conn = put(conn, ~p"/api/v1/actors/me/token", %{"token" => mine})

      assert %{"token" => issued} = json_response(conn, 200)["data"]
      assert issued != mine
      assert Actors.authenticate(mine) == {:error, :unauthorized}
      assert {:ok, _found} = Actors.authenticate(issued)
    end
  end

  describe "authentication" do
    test "refuses a request carrying no token" do
      conn = get(build_conn(), ~p"/api/v1/actors/me")

      assert %{"error" => "unauthorized"} = json_response(conn, 401)
    end

    test "refuses a request carrying the wrong token" do
      conn =
        build_conn()
        |> put_req_header("authorization", "Bearer #{Actors.generate_token()}")
        |> get(~p"/api/v1/actors/me")

      assert %{"error" => "unauthorized"} = json_response(conn, 401)
    end

    # A database nobody has run `mix rinto.actors.setup_human` against. Set up
    # by emptying the column rather than through the API, because there is no
    # endpoint that takes a token away -- an actor without one could not ask
    # for another.
    test "says so when nobody has been issued a token at all" do
      RintoPMO.Repo.update_all(Actor, set: [token: nil])

      conn = get(build_conn(), ~p"/api/v1/actors/me")

      assert %{"error" => "token_not_configured"} = json_response(conn, 401)
    end
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
