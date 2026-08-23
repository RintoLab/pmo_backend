defmodule RintoPMOWeb.V1.BacklinkController do
  use RintoPMOWeb, :controller

  alias RintoPMO.References
  alias RintoPMO.Utils

  @doc """
  Lists everything whose text points at one thing.

  The parameter is the canonical URI rather than a type and an id, which keeps
  one spelling of "this thing" across the whole system: whatever a search result
  hands out, or an author pasted into a body, is what gets asked here.
  """
  def index(conn, %{"target" => target}) when is_binary(target) do
    case References.parse(target) do
      {:ok, reference} ->
        render(conn, :index, backlinks: Utils.module(:links).backlinks(reference))

      :error ->
        {:error, :validation_error, %{target: ["is not a rinto:// URI"]}}
    end
  end

  def index(_conn, _params) do
    {:error, :bad_request, %{target: ["can't be blank"]}}
  end
end
