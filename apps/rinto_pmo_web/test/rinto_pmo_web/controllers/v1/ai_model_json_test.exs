defmodule RintoPMOWeb.V1.AIModelJSONTest do
  @moduledoc """
  A failed discovery reaches a client only through `status` -- the refresh
  endpoint answers 204 either way -- so it has to survive rendering.
  """

  use ExUnit.Case, async: true

  alias RintoPMO.Agent.AIModel
  alias RintoPMOWeb.V1.AIModelJSON

  defp status(overrides) do
    Enum.into(overrides, %{state: :ok, loading?: false, updated_at: nil, error: nil})
  end

  test "renders a loaded catalog" do
    at = DateTime.utc_now()

    model =
      AIModel.new!(%{
        provider: "acme",
        model: "alpha",
        name: "Alpha",
        context_window: 10_000,
        max_output: 1_000,
        thinking: true,
        thinking_levels: [:off, :high],
        images: true
      })

    assert %{
             data: [
               %{
                 provider: "acme",
                 models: [%{model: "alpha", name: "Alpha", thinking_levels: [:off, :high]}]
               }
             ],
             status: %{state: :ok, loading: false, updated_at: ^at, error: nil}
           } =
             AIModelJSON.index(%{
               providers: [%{provider: "acme", models: [model]}],
               status: status(updated_at: at)
             })
  end

  # Rendered with inspect/1: reasons are arbitrary terms, and this is text for
  # an operator rather than a code to branch on -- `state` is that.
  test "renders a failed discovery as diagnostic text" do
    assert %{status: %{state: :error, error: ":pi_not_found"}} =
             AIModelJSON.index(%{
               providers: [],
               status: status(state: :error, error: :pi_not_found)
             })
  end

  test "distinguishes a catalog still loading from one that never loaded" do
    assert %{data: [], status: %{state: :not_loaded, loading: true}} =
             AIModelJSON.index(%{
               providers: [],
               status: status(state: :not_loaded, loading?: true)
             })

    assert %{status: %{state: :not_loaded, loading: false}} =
             AIModelJSON.index(%{providers: [], status: status(state: :not_loaded)})
  end

  # An :ok catalog can be busy: a refresh keeps serving what it is replacing.
  test "reports a usable catalog that is being refreshed" do
    assert %{status: %{state: :ok, loading: true}} =
             AIModelJSON.index(%{providers: [], status: status(loading?: true)})
  end
end
