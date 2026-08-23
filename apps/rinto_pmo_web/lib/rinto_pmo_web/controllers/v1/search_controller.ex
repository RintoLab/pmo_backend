defmodule RintoPMOWeb.V1.SearchController do
  use RintoPMOWeb, :controller

  alias RintoPMO.Utils

  @doc """
  Searches one kind of thing by meaning.

  `type` is required. A caller that has not said what it is looking for has not
  decided yet, and defaulting would mean quietly searching one kind of thing
  while it believed it was searching everything -- a wrong answer that looks
  like a right one.

  Archived things are left out unless asked for. This differs from
  `GET /backlinks` on purpose -- that answers "who pointed at this", where
  leaving anything out would be wrong, while this answers "find me something to
  use", and archived means "not in use".
  """
  def index(conn, %{"q" => query, "type" => type} = params)
      when is_binary(query) and is_binary(type) do
    opts = [
      type: type,
      project_id: params["project_id"],
      include_archived: params["include_archived"] == "true"
    ]

    with {:ok, opts} <- put_positive(opts, params, "limit", :limit),
         {:ok, opts} <- put_positive(opts, params, "recall_limit", :recall_limit),
         {:ok, results} <- Utils.module(:search).search(query, opts) do
      render(conn, :index, results: results)
    end
  end

  def index(_conn, %{"q" => query}) when is_binary(query) do
    {:error, :bad_request, %{type: ["can't be blank"]}}
  end

  def index(_conn, _params) do
    {:error, :bad_request, %{q: ["can't be blank"]}}
  end

  # Absent means "use the default", so only a present-and-unusable value is a
  # mistake. Zero and negative are refused rather than floored: a caller asking
  # for none of something meant something, and it was not this.
  defp put_positive(opts, params, param, key) do
    case Map.fetch(params, param) do
      :error ->
        {:ok, opts}

      {:ok, value} ->
        case Integer.parse(value) do
          {parsed, ""} when parsed > 0 -> {:ok, Keyword.put(opts, key, parsed)}
          _invalid -> {:error, :bad_request, %{key => ["is invalid"]}}
        end
    end
  end
end
