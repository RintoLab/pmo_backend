defmodule RintoPMOWeb.FallbackController do
  @moduledoc false

  use RintoPMOWeb, :controller

  def call(conn, {:error, %Ecto.Changeset{} = changeset}) do
    details = RintoPMOWeb.ChangesetJSON.translate_errors(changeset)

    render_error(conn, :validation_error, details)
  end

  def call(conn, {:error, code}) when is_atom(code) do
    render_error(conn, code, %{})
  end

  def call(conn, {:error, code, details}) when is_atom(code) and is_map(details) do
    render_error(conn, code, details)
  end

  defp render_error(conn, code, details) do
    status = RintoPMOWeb.ErrorJSON.status!(code)

    conn
    |> put_status(status)
    |> put_view(json: RintoPMOWeb.ErrorJSON)
    |> render("#{status}.json", code: code, details: details)
  end
end
