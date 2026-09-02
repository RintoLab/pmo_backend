defmodule RintoPMO.Agent.CodexAuthTest do
  use ExUnit.Case, async: false

  import Hammox

  alias RintoPMO.Agent.CodexAuth
  alias RintoPMO.Agent.CodexAuth.HelperMock
  alias RintoPMO.Agent.PiInstallation

  setup :verify_on_exit!

  setup do
    previous = Application.get_env(:rinto_pmo, :pi_agent_dir)
    dir = Path.join(System.tmp_dir!(), "codex-auth-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    Application.put_env(:rinto_pmo, :pi_agent_dir, dir)

    on_exit(fn ->
      Application.put_env(:rinto_pmo, :pi_agent_dir, previous)
      File.rm_rf(dir)
    end)

    server = start_supervised!({CodexAuth, name: nil, startup_timeout: 10_000})
    allow(HelperMock, self(), server)

    %{server: server, auth_path: PiInstallation.auth_path()}
  end

  test "moves idle -> pending -> completed and recognizes the SDK-written credential", context do
    expect_login(context, fn owner, ref -> send(owner, stdout(ref, device_code())) end)

    assert {:ok, pending} = CodexAuth.start_auth(context.server)
    assert pending.status == :pending
    assert pending.user_code == "ABCD-1234"

    write_credentials(context.auth_path, %{
      "openai-codex" => oauth_credential(),
      "anthropic" => %{"type" => "api_key", "key" => "test-only"}
    })

    send(context.server, stdout("helper-1", completed()))
    _ = :sys.get_state(context.server)

    assert %{status: :completed, authenticated: true} = CodexAuth.status(context.server)
  end

  test "repeated start returns the same pending device code without another helper", context do
    expect_login(context, fn owner, ref -> send(owner, stdout(ref, device_code())) end)

    assert {:ok, first} = CodexAuth.start_auth(context.server)
    assert {:ok, second} = CodexAuth.start_auth(context.server)
    assert first.user_code == second.user_code

    expect(HelperMock, :stop, fn "helper-1" -> :ok end)
    assert {:ok, %{status: :cancelled}} = CodexAuth.cancel(context.server)
  end

  test "cancel terminates the helper and releases a start waiting for a device code", context do
    test_pid = self()

    expect_login(context, fn owner, ref ->
      send(test_pid, {:helper_started, ref})
      send(owner, {:helper_ready, ref})
    end)

    expect(HelperMock, :stop, fn "helper-1" -> :ok end)

    task = Task.async(fn -> CodexAuth.start_auth(context.server) end)
    assert_receive {:helper_started, "helper-1"}
    assert {:ok, %{status: :cancelled}} = CodexAuth.cancel(context.server)
    assert {:ok, %{status: :cancelled}} = Task.await(task)
  end

  test "timeout stops the helper and becomes expired", context do
    expect_login(context, fn _owner, _ref -> :ok end)
    expect(HelperMock, :stop, fn "helper-1" -> :ok end)

    task = Task.async(fn -> CodexAuth.start_auth(context.server) end)
    _ = :sys.get_state(context.server)
    send(context.server, {:auth_timeout, "helper-1"})

    assert {:ok, %{status: :expired, error: "auth_expired"}} = Task.await(task)
  end

  test "helper crash and malformed JSONL become safe failed states", context do
    expect_login(context, fn owner, ref ->
      send(owner, {:os_process, ref, {:exit, {:exit, 9}}})
    end)

    assert {:ok, %{status: :failed, error: "helper_crashed"}} =
             CodexAuth.start_auth(context.server)

    expect_login(context, fn owner, ref -> send(owner, stdout(ref, "not-json")) end)
    expect(HelperMock, :stop, fn "helper-1" -> :ok end)

    assert {:ok, %{status: :failed, error: "malformed_helper_output"}} =
             CodexAuth.start_auth(context.server)
  end

  test "helper error becomes failed without exposing its message", context do
    line =
      JSON.encode!(%{
        type: "error",
        provider: "openai-codex",
        code: "auth_failed",
        message: "upstream details must not be returned"
      })

    expect_login(context, fn owner, ref -> send(owner, stdout(ref, line)) end)

    assert {:ok, %{status: :failed, error: "auth_failed"} = state} =
             CodexAuth.start_auth(context.server)

    refute inspect(state) =~ "upstream details"
  end

  test "logout delegates to ModelRuntime helper semantics and preserves other providers",
       context do
    write_credentials(context.auth_path, %{
      "openai-codex" => oauth_credential(),
      "anthropic" => %{"type" => "api_key", "key" => "test-only"}
    })

    expect(HelperMock, :logout, fn opts ->
      path = Keyword.fetch!(opts, :auth_path)
      {:ok, credentials} = path |> File.read!() |> JSON.decode()
      File.write!(path, JSON.encode!(Map.delete(credentials, "openai-codex")))
      File.chmod!(path, 0o600)
      :ok
    end)

    assert {:ok, %{status: :idle, authenticated: false}} = CodexAuth.logout(context.server)
    {:ok, remaining} = context.auth_path |> File.read!() |> JSON.decode()
    assert remaining == %{"anthropic" => %{"type" => "api_key", "key" => "test-only"}}
    assert {:ok, %{mode: 0o100600}} = File.stat(context.auth_path)
  end

  defp expect_login(context, callback) do
    expect(HelperMock, :start_login, fn owner, opts ->
      assert Keyword.fetch!(opts, :auth_path) == context.auth_path
      ref = "helper-1"
      callback.(owner, ref)
      {:ok, ref}
    end)
  end

  defp stdout(ref, line), do: {:os_process, ref, {:stdout, line}}

  defp device_code do
    JSON.encode!(%{
      type: "device_code",
      provider: "openai-codex",
      verificationUrl: "https://auth.openai.com/codex/device",
      userCode: "ABCD-1234",
      expiresInSeconds: 900
    })
  end

  defp completed,
    do: JSON.encode!(%{type: "completed", provider: "openai-codex", success: true})

  defp write_credentials(path, credentials) do
    File.write!(path, JSON.encode!(credentials))
    File.chmod!(path, 0o600)
  end

  defp oauth_credential do
    %{
      "type" => "oauth",
      "access" => "test-access",
      "refresh" => "test-refresh",
      "expires" => 1_788_336_000_000,
      "accountId" => "test-account"
    }
  end
end
