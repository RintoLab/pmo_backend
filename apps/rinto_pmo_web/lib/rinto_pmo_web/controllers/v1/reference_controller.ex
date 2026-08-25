defmodule RintoPMOWeb.V1.ReferenceController do
  use RintoPMOWeb, :controller

  alias RintoPMO.Utils

  @doc """
  Resolves a batch of `rinto://` URIs into enough of their targets to render.

  A POST because the input is a list of URIs that each contain slashes: a body
  with thirty references would need every one of them escaped into a query
  string long enough to be refused. `POST /documents/preview_blocks` is the
  same shape -- a read that cannot fit in a URL, storing nothing.
  """
  def resolve(conn, %{"uris" => uris}) when is_list(uris) do
    if Enum.all?(uris, &is_binary/1) do
      with {:ok, references} <- Utils.module(:reference_resolver).resolve(uris) do
        render(conn, :resolve, references: references)
      end
    else
      {:error, :bad_request, %{uris: ["must be a list of strings"]}}
    end
  end

  def resolve(_conn, _params) do
    {:error, :bad_request, %{uris: ["can't be blank"]}}
  end
end
