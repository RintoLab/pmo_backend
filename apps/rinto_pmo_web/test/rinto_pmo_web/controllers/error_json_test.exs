defmodule RintoPMOWeb.ErrorJSONTest do
  use ExUnit.Case, async: true

  alias RintoPMOWeb.ErrorJSON

  test "renders a structured error with details" do
    assert ErrorJSON.render("422.json", %{
             code: :validation_error,
             errors: %{name: ["can't be blank"]}
           }) == %{
             status: 422,
             code: :validation_error,
             errors: %{name: ["can't be blank"]}
           }
  end

  test "renders a structured error without details" do
    assert ErrorJSON.render("409.json", %{code: :conflict}) == %{
             status: 409,
             code: :conflict
           }
  end

  test "renders standard errors" do
    assert ErrorJSON.render("400.json", %{}) == %{status: 400, code: :bad_request}
    assert ErrorJSON.render("404.json", %{}) == %{status: 404, code: :not_found}
    assert ErrorJSON.render("500.json", %{}) == %{status: 500, code: :internal_server_error}
  end

  test "falls back to an internal server error" do
    assert ErrorJSON.template_not_found("unknown.json", %{}) == %{
             status: 500,
             code: :internal_server_error
           }
  end
end
