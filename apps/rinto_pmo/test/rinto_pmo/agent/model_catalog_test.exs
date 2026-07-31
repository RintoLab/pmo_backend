defmodule RintoPMO.Agent.ModelCatalogTest do
  use ExUnit.Case, async: false

  alias RintoPMO.Agent.AIModel
  alias RintoPMO.Agent.ModelCatalog

  setup do
    models = [
      AIModel.new!(%{
        provider: "openai",
        model: "gpt-test",
        context_window: 100_000,
        max_output: 8_000,
        thinking: true,
        images: true
      }),
      AIModel.new!(%{
        provider: "acme",
        model: "alpha",
        context_window: 10_000,
        max_output: 1_000,
        thinking: false,
        images: false
      }),
      AIModel.new!(%{
        provider: "acme",
        model: "beta",
        context_window: 20_000,
        max_output: 2_000,
        thinking: true,
        images: false
      })
    ]

    :ok = ModelCatalog.replace!(models)
    %{models: models}
  end

  test "list_models/0 returns cached AIModel structs ordered by provider and model" do
    assert [
             %AIModel{provider: "acme", model: "alpha"},
             %AIModel{provider: "acme", model: "beta"},
             %AIModel{provider: "openai", model: "gpt-test"}
           ] = ModelCatalog.list_models()
  end

  test "list_providers/0 groups models under each provider" do
    assert [
             %{
               provider: "acme",
               models: [
                 %AIModel{model: "alpha"},
                 %AIModel{model: "beta"}
               ]
             },
             %{
               provider: "openai",
               models: [%AIModel{model: "gpt-test"}]
             }
           ] = ModelCatalog.list_providers()
  end

  test "status/0 reports a successful load after replace" do
    assert {:ok, %DateTime{}} = ModelCatalog.status()
  end
end
