defmodule RintoPMOWeb.V1.AIRoleController do
  @moduledoc """
  How the two automatic jobs call a model.

  Three verbs and no `POST`. The jobs are `RintoPMO.AIRoles.keys/0` and nothing
  else -- a role exists because code reads it by name, so a row a client
  invented would be configuration for work that never happens. An unknown key
  is a `404` for that reason: it is not a bad request body, there is no such
  role to write to.

  Every response carries the whole set, `null` for a job nobody has configured,
  so a client replaces what it is holding rather than merging a patch into it.
  """

  use RintoPMOWeb, :controller

  alias RintoPMO.AIRoles

  def index(conn, _params) do
    render(conn, :index, roles: AIRoles.list_roles())
  end

  @doc """
  Configures a job, replacing whatever was there.

  A `PUT` and not a `PATCH`: the row is four fields on one form, and it is
  written whole. Leaving `system_prompt` out of the body clears it.

  `provider`, `model` and `thinking_level` are required together -- a role
  holding two of the three is a call nobody can make, and the request that
  wrote it is the last place anybody is looking.
  """
  def update(conn, %{"key" => key} = params) do
    with {:ok, roles} <- AIRoles.put_role(key, Map.delete(params, "key")) do
      render(conn, :index, roles: roles)
    end
  end

  @doc """
  Empties a job.

  What that means belongs to the job and the two answer differently: naming
  falls back to the topic's own model configuration, estimation refuses. See
  `RintoPMO.AIRoles`.

  Answers with the set rather than `204`, because emptying one role is a change
  to the screen the client is looking at and it needs the same shape back that
  `index` gives it. Emptying an empty role succeeds.
  """
  def delete(conn, %{"key" => key}) do
    with {:ok, roles} <- AIRoles.delete_role(key) do
      render(conn, :index, roles: roles)
    end
  end
end
