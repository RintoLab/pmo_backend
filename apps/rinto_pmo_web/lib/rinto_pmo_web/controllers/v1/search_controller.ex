defmodule RintoPMOWeb.V1.SearchController do
  use RintoPMOWeb, :controller

  alias RintoPMO.Utils

  @doc """
  Searches one kind of thing by meaning.

  `type` defaults to `block`, which is where a body's content actually lives: a
  document is found through the section that says the thing, not through its
  title. Ask for `document` to get the document instead of the section.

  Archived things are left out unless asked for. This differs from
  `GET /backlinks` on purpose -- that answers "who pointed at this", where
  leaving anything out would be wrong, while this answers "find me something to
  use", and archived means "not in use".
  """
  def index(conn, %{"q" => query} = params) when is_binary(query) do
    opts = [
      type: params["type"],
      project_id: params["project_id"],
      include_archived: params["include_archived"] == "true"
    ]

    with {:ok, opts} <- put_limit(opts, params),
         {:ok, results} <- Utils.module(:search).search(query, opts) do
      render(conn, :index, results: results)
    end
  end

  def index(_conn, _params) do
    {:error, :bad_request, %{q: ["can't be blank"]}}
  end

  defp put_limit(opts, %{"limit" => limit}) do
    case Integer.parse(limit) do
      {parsed, ""} when parsed > 0 -> {:ok, Keyword.put(opts, :limit, parsed)}
      _invalid -> {:error, :bad_request, %{limit: ["is invalid"]}}
    end
  end

  defp put_limit(opts, _params), do: {:ok, opts}
end
