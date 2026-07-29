defmodule RintoPMOWeb.ErrorJSON do
  @moduledoc false

  def render(<<status::binary-size(3)>> <> ".json", %{code: code} = assigns) do
    response = %{
      status: String.to_integer(status),
      code: code
    }

    case Map.get(assigns, :errors) do
      nil -> response
      errors -> Map.put(response, :errors, errors)
    end
  end

  def render("400.json", _assigns) do
    %{status: 400, code: :bad_request}
  end

  def render("404.json", _assigns) do
    %{status: 404, code: :not_found}
  end

  def render("500.json", _assigns) do
    %{status: 500, code: :internal_server_error}
  end

  def template_not_found(_template, _assigns) do
    %{status: 500, code: :internal_server_error}
  end
end
