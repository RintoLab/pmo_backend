defmodule RintoPMO.Agent.ModelCatalogTest do
  @moduledoc """
  Each test runs its own catalog, named after itself and handed its own
  `:discover`. That keeps them off the application's instance -- and off pi --
  and lets them decide both what a run returns and when it finishes, which is
  what the timing-dependent cases need. It is also what makes this module
  `async: true` despite the catalog being a named process with a named table.
  """

  use ExUnit.Case, async: true

  @moduletag :capture_log

  alias RintoPMO.Agent.AIModel
  alias RintoPMO.Agent.ModelCatalog

  defp model(provider, id) do
    AIModel.new!(%{
      provider: provider,
      model: id,
      name: String.upcase(id),
      context_window: 10_000,
      max_output: 1_000,
      thinking: false,
      thinking_levels: [:off],
      images: false
    })
  end

  defp start_catalog(opts) do
    name = :"catalog_#{System.unique_integer([:positive])}"
    opts = Keyword.merge([name: name, load_on_start: false], opts)

    {:ok, pid} = start_supervised({ModelCatalog, opts})

    %{catalog: name, pid: pid}
  end

  # A refresh is a cast, so it has not necessarily begun when the call returns.
  # A subsequent call is processed after it, making the effect observable
  # without sleeping.
  defp sync(catalog), do: :sys.get_state(catalog)

  defp await_idle(catalog) do
    Enum.reduce_while(1..300, :timeout, fn _i, _acc ->
      if Map.fetch!(ModelCatalog.status(catalog), :loading?) do
        Process.sleep(10)
        {:cont, :timeout}
      else
        {:halt, :ok}
      end
    end)
  end

  # Blocks until released, so a test can observe the in-flight state.
  defp blocking_discovery do
    test_pid = self()

    fn ->
      send(test_pid, :discovery_started)

      receive do
        :release -> {:ok, []}
      after
        5_000 -> {:ok, []}
      end
    end
  end

  defp release_and_settle(catalog) do
    send(:sys.get_state(catalog).task.pid, :release)
    assert :ok = await_idle(catalog)
  end

  describe "reading a loaded catalog" do
    setup do
      models = [model("openai", "gpt-test"), model("acme", "alpha"), model("acme", "beta")]
      context = start_catalog(discover: fn -> {:ok, models} end, load_on_start: true)

      assert :ok = await_idle(context.catalog)

      context
    end

    test "list_models/1 orders by provider then model", %{catalog: catalog} do
      assert [
               %AIModel{provider: "acme", model: "alpha"},
               %AIModel{provider: "acme", model: "beta"},
               %AIModel{provider: "openai", model: "gpt-test"}
             ] = ModelCatalog.list_models(catalog)
    end

    test "list_providers/1 groups models under each provider", %{catalog: catalog} do
      assert [
               %{provider: "acme", models: [%AIModel{model: "alpha"}, %AIModel{model: "beta"}]},
               %{provider: "openai", models: [%AIModel{model: "gpt-test"}]}
             ] = ModelCatalog.list_providers(catalog)
    end

    test "status/1 reports a successful load", %{catalog: catalog} do
      assert %{state: :ok, loading?: false, updated_at: %DateTime{}, error: nil} =
               ModelCatalog.status(catalog)
    end
  end

  describe "boot-time loading" do
    test "discovers once at startup when asked" do
      %{catalog: catalog} =
        start_catalog(discover: fn -> {:ok, [model("acme", "alpha")]} end, load_on_start: true)

      assert :ok = await_idle(catalog)
      assert [%AIModel{model: "alpha"}] = ModelCatalog.list_models(catalog)
    end

    # A slow or missing pi must delay only the catalog, never application boot.
    test "start_link returns without waiting for discovery" do
      %{catalog: catalog} = start_catalog(discover: blocking_discovery(), load_on_start: true)

      assert_receive :discovery_started, 1_000
      assert Map.fetch!(ModelCatalog.status(catalog), :loading?)

      release_and_settle(catalog)
    end

    test "an untouched catalog reads as empty and not_loaded" do
      %{catalog: catalog} = start_catalog([])

      assert ModelCatalog.list_models(catalog) == []

      assert %{state: :not_loaded, loading?: false, updated_at: nil, error: nil} =
               ModelCatalog.status(catalog)
    end

    # This is what keeps the application's own instance off pi during tests.
    test "the test environment does not load on start" do
      config = Application.get_env(:rinto_pmo, ModelCatalog, [])

      assert Keyword.get(config, :load_on_start) == false
    end
  end

  describe "refresh/1" do
    test "returns immediately rather than waiting for discovery" do
      %{catalog: catalog} = start_catalog(discover: blocking_discovery())

      assert :ok = ModelCatalog.refresh(catalog)
      sync(catalog)

      assert_receive :discovery_started, 1_000
      assert Map.fetch!(ModelCatalog.status(catalog), :loading?)

      release_and_settle(catalog)
    end

    test "replaces the catalog once discovery finishes" do
      %{catalog: catalog} = start_catalog(discover: fn -> {:ok, [model("refreshed", "x")]} end)

      :ok = ModelCatalog.refresh(catalog)
      sync(catalog)
      assert :ok = await_idle(catalog)

      assert [%AIModel{provider: "refreshed", model: "x"}] = ModelCatalog.list_models(catalog)
      assert %{state: :ok, loading?: false, error: nil} = ModelCatalog.status(catalog)
    end

    # A refresh that fails must not blank the catalog: stale models beat none.
    test "keeps the previous models when discovery fails" do
      %{catalog: catalog} = start_catalog(discover: fn -> {:error, :pi_not_found} end)

      :ok = ModelCatalog.replace!([model("acme", "alpha")], catalog)
      before = ModelCatalog.list_models(catalog)

      :ok = ModelCatalog.refresh(catalog)
      sync(catalog)
      assert :ok = await_idle(catalog)

      assert ModelCatalog.list_models(catalog) == before

      assert %{state: :error, loading?: false, error: :pi_not_found} =
               ModelCatalog.status(catalog)
    end

    # Discovery raises for real: `File.mkdir_p!` on a read-only tmp and
    # `AIModel.new!` on a malformed payload both do. Were the task linked, that
    # would kill the catalog, and a deterministic failure would crash-loop it
    # until the supervisor gave up on the whole application.
    test "records a crashed discovery rather than dying with it" do
      %{catalog: catalog, pid: pid} = start_catalog(discover: fn -> raise "boom" end)

      :ok = ModelCatalog.refresh(catalog)
      sync(catalog)
      assert :ok = await_idle(catalog)

      assert %{state: :error, error: {:discovery_crashed, _reason}} = ModelCatalog.status(catalog)
      assert Process.alive?(pid)
    end

    test "a refresh in flight absorbs further requests" do
      %{catalog: catalog} = start_catalog(discover: blocking_discovery())

      :ok = ModelCatalog.refresh(catalog)
      sync(catalog)
      assert_receive :discovery_started, 1_000

      # A second run would announce itself; the in-flight one must swallow these.
      :ok = ModelCatalog.refresh(catalog)
      :ok = ModelCatalog.refresh(catalog)
      sync(catalog)

      refute_received :discovery_started

      release_and_settle(catalog)
    end
  end
end
