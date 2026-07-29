defmodule RintoPMOWeb.FallbackController do
  @moduledoc false

  use RintoPMOWeb, :controller

  def call(conn, {:error, %Ecto.Changeset{} = changeset}) do
    validation_error(conn, changeset)
  end

  defp validation_error(conn, changeset) do
    errors = RintoPMOWeb.ChangesetJSON.translate_errors(changeset)

    render_error(conn, 422, code: :validation_error, errors: errors)
  end

  defp render_error(conn, status, assigns) do
    conn
    |> put_status(status)
    |> put_view(RintoPMOWeb.ErrorJSON)
    |> render("#{status}.json", assigns)
  end
end
