defmodule RintoPMOWeb.V1.CodexAuthControllerTest do
  use RintoPMOWeb.ConnCase, async: false

  alias RintoPMO.Agent.CodexAuth
  alias RintoPMO.Agent.CodexAuth.HelperMock
  alias RintoPMO.Agent.PiInstallation

  setup do
    previous = Application.get_env(:rinto_pmo, :pi_agent_dir)
    dir = Path.join(System.tmp_dir!(), "codex-auth-api-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    Application.put_env(:rinto_pmo, :pi_agent_dir, dir)
    :ok = CodexAuth.reset()

    on_exit(fn ->
      :ok = CodexAuth.reset()
      Application.put_env(:rinto_pmo, :pi_agent_dir, previous)
      File.rm_rf(dir)
    end)

    %{auth_path: PiInstallation.auth_path()}
  end

  test "GET status reports idle without reading or returning credential material", %{conn: conn} do
    assert %{
             "provider" => "openai-codex",
             "authenticated" => false,
             "status" => "idle"
           } = conn |> get(~p"/api/v1/ai_auth/openai_codex") |> json_response(200)
  end

  test "POST device starts once and returns the same pending code on repetition", context do
    expect(HelperMock, :start_login, 1, fn owner, opts ->
      assert Keyword.fetch!(opts, :auth_path) == context.auth_path

      send(
        owner,
        {:os_process, "api-helper", {:stdout, device_code()}}
      )

      {:ok, "api-helper"}
    end)

    allow(HelperMock, self(), CodexAuth)

    first =
      context.conn
      |> post(~p"/api/v1/ai_auth/openai_codex/device")
      |> json_response(200)

    assert %{
             "provider" => "openai-codex",
             "authenticated" => false,
             "status" => "pending",
             "verificationUrl" => "https://auth.openai.com/codex/device",
             "userCode" => "ABCD-1234",
             "expiresInSeconds" => expires
           } = first

    assert expires in 899..900

    second =
      build_conn()
      |> authenticate()
      |> post(~p"/api/v1/ai_auth/openai_codex/device")
      |> json_response(200)

    assert second["userCode"] == first["userCode"]

    expect(HelperMock, :stop, fn "api-helper" -> :ok end)
    allow(HelperMock, self(), CodexAuth)
    :ok = CodexAuth.reset()
  end

  test "POST cancel terminates a pending helper", context do
    expect(HelperMock, :start_login, fn owner, _opts ->
      send(owner, {:os_process, "api-helper", {:stdout, device_code()}})
      {:ok, "api-helper"}
    end)

    allow(HelperMock, self(), CodexAuth)

    _response =
      context.conn
      |> post(~p"/api/v1/ai_auth/openai_codex/device")
      |> json_response(200)

    expect(HelperMock, :stop, fn "api-helper" -> :ok end)
    allow(HelperMock, self(), CodexAuth)

    assert %{"status" => "cancelled", "authenticated" => false} =
             build_conn()
             |> authenticate()
             |> post(~p"/api/v1/ai_auth/openai_codex/cancel")
             |> json_response(200)

    assert %{"error" => "codex_auth_not_pending"} =
             build_conn()
             |> authenticate()
             |> post(~p"/api/v1/ai_auth/openai_codex/cancel")
             |> json_response(409)
  end

  test "DELETE logout removes only OpenAI Codex through the helper", context do
    File.write!(
      context.auth_path,
      JSON.encode!(%{
        "openai-codex" => %{
          "type" => "oauth",
          "access" => "test-access",
          "refresh" => "test-refresh",
          "expires" => 1_788_336_000_000
        },
        "anthropic" => %{"type" => "api_key", "key" => "test-only"}
      })
    )

    expect(HelperMock, :logout, fn opts ->
      path = Keyword.fetch!(opts, :auth_path)
      {:ok, credentials} = path |> File.read!() |> JSON.decode()
      File.write!(path, JSON.encode!(Map.delete(credentials, "openai-codex")))
      File.chmod!(path, 0o600)
      :ok
    end)

    allow(HelperMock, self(), CodexAuth)

    assert %{"status" => "idle", "authenticated" => false} =
             context.conn
             |> delete(~p"/api/v1/ai_auth/openai_codex")
             |> json_response(200)

    {:ok, remaining} = context.auth_path |> File.read!() |> JSON.decode()
    assert Map.has_key?(remaining, "anthropic")
    refute Map.has_key?(remaining, "openai-codex")
  end

  defp device_code do
    JSON.encode!(%{
      type: "device_code",
      provider: "openai-codex",
      verificationUrl: "https://auth.openai.com/codex/device",
      userCode: "ABCD-1234",
      expiresInSeconds: 900
    })
  end
end
