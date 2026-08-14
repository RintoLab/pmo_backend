defmodule RintoPMOWeb.Plugs.ActorToken do
  @moduledoc """
  Turns the request's token into `conn.assigns.current_actor`.

      Authorization: Bearer <token>

  Every route under `/api/v1` goes through this, with no exceptions. There is
  no endpoint to bootstrap from and none to recover with: the token is agreed
  in advance and configured on both ends -- `RINTO_TOKEN` for the server, a
  config file for each client -- so a caller that cannot authenticate has a
  configuration problem, which is not one this API could fix for it anyway.

  A server given no token answers nothing, which is the right answer: nobody
  has said what it should let in.

  The token replaces the client-supplied `actor_id` for anything a person does.
  It cannot replace all of them: `POST /tasks/{id}/assign` names who is being
  handed the work, `PUT /settings/{key}` names an AI persona, and those stay in
  the body because they are about somebody other than the caller.

  ## Why a plug and not the injection seam

  This reads `RintoPMO.Actors` directly rather than through
  `RintoPMO.Utils.module/1`. Authentication runs before every controller in the
  application, so routing it through the mock seam would make each of a hundred
  controller tests declare an expectation for a question none of them are
  asking about. `RintoPMOWeb.ConnCase` issues a real token instead.
  """

  @behaviour Plug

  import Plug.Conn

  alias RintoPMO.Actors

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    case Actors.authenticate(token(conn)) do
      {:ok, actor} -> assign(conn, :current_actor, actor)
      {:error, code} -> refuse(conn, code)
    end
  end

  @doc """
  The actor the request is being made by.

  Raises rather than returning `nil`: reaching a controller without one means
  this plug was left off a pipeline, and a write attributed to `nil` would be
  found much later, in the data.
  """
  @spec current_actor!(Plug.Conn.t()) :: RintoPMO.Actors.Actor.t()
  def current_actor!(%Plug.Conn{assigns: %{current_actor: actor}}), do: actor

  def current_actor!(%Plug.Conn{}) do
    raise "the request has no current actor; #{inspect(__MODULE__)} is not in its pipeline"
  end

  # Only the `Bearer` scheme. A bare token in the header, or one in the query
  # string, would end up in access logs and shell history of anyone who copied
  # the URL.
  defp token(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token | _rest] -> String.trim(token)
      _absent_or_other_scheme -> nil
    end
  end

  # Rendered through `RintoPMOWeb.ErrorJSON` like every other refusal, so a
  # client parses one error shape whether it was turned away here or by a
  # controller.
  defp refuse(conn, code) do
    status = RintoPMOWeb.ErrorJSON.status!(code)

    conn
    |> put_status(status)
    |> Phoenix.Controller.put_view(json: RintoPMOWeb.ErrorJSON)
    |> Phoenix.Controller.render("#{status}.json", code: code, details: %{})
    |> halt()
  end
end
