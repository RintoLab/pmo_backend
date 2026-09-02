defmodule RintoPMO.Agent.CodexAuth do
  @moduledoc """
  Single-instance OpenAI Codex device authorization state machine.

  The process owns the helper and is its output owner, so cancellation or a
  supervisor shutdown also reaps the OAuth poller. Only display-safe device
  information is retained here; Pi's SDK writes credentials directly to its
  own `auth.json`.
  """

  use GenServer

  require Logger

  alias RintoPMO.Agent.CodexAuth.Parser
  alias RintoPMO.Agent.PiInstallation
  alias RintoPMO.Utils

  @provider "openai-codex"
  @default_startup_timeout 30_000

  @type status :: :idle | :pending | :completed | :failed | :expired | :cancelled

  @type snapshot :: %{
          required(:provider) => String.t(),
          required(:authenticated) => boolean(),
          required(:status) => status(),
          optional(:verification_url) => String.t(),
          optional(:user_code) => String.t(),
          optional(:expires_in_seconds) => non_neg_integer(),
          optional(:error) => String.t()
        }

  defstruct status: :idle,
            helper_ref: nil,
            device: nil,
            deadline: nil,
            timer: nil,
            waiters: [],
            error: nil,
            startup_timeout: @default_startup_timeout

  @doc false
  def start_link(opts \\ []) do
    case Keyword.get(opts, :name, __MODULE__) do
      nil -> GenServer.start_link(__MODULE__, opts)
      name -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  @spec status(GenServer.server()) :: snapshot()
  def status(server \\ __MODULE__), do: GenServer.call(server, :status)

  @spec start_auth(GenServer.server()) :: {:ok, snapshot()} | {:error, :auth_unavailable}
  def start_auth(server \\ __MODULE__) do
    timeout = configured_startup_timeout() + 2_000
    GenServer.call(server, :start_auth, timeout)
  end

  @spec cancel(GenServer.server()) :: {:ok, snapshot()} | {:error, :not_pending}
  def cancel(server \\ __MODULE__), do: GenServer.call(server, :cancel, 15_000)

  @spec logout(GenServer.server()) :: {:ok, snapshot()} | {:error, :auth_unavailable}
  def logout(server \\ __MODULE__), do: GenServer.call(server, :logout, 35_000)

  @doc false
  def reset(server \\ __MODULE__), do: GenServer.call(server, :reset)

  @impl true
  def init(opts) do
    {:ok,
     %__MODULE__{
       startup_timeout: Keyword.get(opts, :startup_timeout, configured_startup_timeout())
     }}
  end

  @impl true
  def handle_call(:status, _from, state) do
    state = normalize(state)
    {:reply, snapshot(state), state}
  end

  def handle_call(:reset, _from, state) do
    stop_helper(state.helper_ref)
    state = state |> terminal(:idle) |> reply_waiters()
    {:reply, :ok, state}
  end

  def handle_call(:start_auth, from, state) do
    state = normalize(state)

    cond do
      state.status == :pending and state.device != nil ->
        {:reply, {:ok, snapshot(state)}, state}

      state.status == :pending ->
        {:noreply, %{state | waiters: [from | state.waiters]}}

      authenticated?() ->
        state = terminal(state, :completed)
        {:reply, {:ok, snapshot(state)}, state}

      true ->
        start_helper(from, state)
    end
  end

  def handle_call(:cancel, _from, %{status: :pending} = state) do
    stop_helper(state.helper_ref)
    state = state |> terminal(:cancelled) |> reply_waiters()
    {:reply, {:ok, snapshot(state)}, state}
  end

  def handle_call(:cancel, _from, state), do: {:reply, {:error, :not_pending}, normalize(state)}

  def handle_call(:logout, _from, state) do
    stop_helper(state.helper_ref)
    state = state |> terminal(:cancelled) |> reply_waiters()

    case helper().logout(auth_path: PiInstallation.auth_path()) do
      :ok ->
        state = terminal(state, :idle)
        {:reply, {:ok, snapshot(state)}, state}

      {:error, reason} ->
        Logger.warning("Pi Codex OAuth logout helper failed: #{safe_reason(reason)}")
        state = terminal(state, :failed, "logout_failed")
        {:reply, {:error, :auth_unavailable}, state}
    end
  end

  @impl true
  def handle_info({:os_process, ref, {:stdout, line}}, %{helper_ref: ref} = state) do
    case Parser.parse(line) do
      {:ok, {:device_code, device}} ->
        state = state |> put_device(device) |> reply_waiters()
        {:noreply, state}

      {:ok, :completed} ->
        if authenticated?() do
          state = state |> terminal(:completed) |> reply_waiters()
          {:noreply, state}
        else
          fail(state, "credential_missing")
        end

      {:ok, {:error, code, _message}} ->
        fail(state, safe_code(code))

      {:error, :malformed_jsonl} ->
        stop_helper(ref)
        fail(state, "malformed_helper_output")
    end
  end

  def handle_info({:os_process, ref, {:stderr, line}}, %{helper_ref: ref} = state) do
    Logger.debug("Pi Codex OAuth helper diagnostic: #{sanitize_diagnostic(line)}")
    {:noreply, state}
  end

  def handle_info({:os_process, ref, {:exit, status}}, %{helper_ref: ref} = state) do
    Logger.warning("Pi Codex OAuth helper exited before completion: #{safe_reason(status)}")
    fail(state, "helper_crashed")
  end

  def handle_info({:auth_timeout, ref}, %{helper_ref: ref} = state) do
    stop_helper(ref)
    state = state |> terminal(:expired, "auth_expired") |> reply_waiters()
    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    stop_helper(state.helper_ref)
    :ok
  end

  defp start_helper(from, state) do
    case helper().start_login(self(), auth_path: PiInstallation.auth_path()) do
      {:ok, ref} ->
        timer = Process.send_after(self(), {:auth_timeout, ref}, state.startup_timeout)

        {:noreply,
         %{
           state
           | status: :pending,
             helper_ref: ref,
             device: nil,
             deadline: deadline(state.startup_timeout),
             timer: timer,
             waiters: [from],
             error: nil
         }}

      {:error, reason} ->
        Logger.warning("Pi Codex OAuth helper could not start: #{safe_reason(reason)}")
        state = terminal(state, :failed, "helper_unavailable")
        {:reply, {:error, :auth_unavailable}, state}
    end
  end

  defp put_device(state, device) do
    cancel_timer(state.timer)
    timeout = :timer.seconds(device.expires_in_seconds)
    timer = Process.send_after(self(), {:auth_timeout, state.helper_ref}, timeout)

    %{
      state
      | status: :pending,
        device: device,
        deadline: deadline(timeout),
        timer: timer,
        error: nil
    }
  end

  defp fail(state, code) do
    state = state |> terminal(:failed, code) |> reply_waiters()
    {:noreply, state}
  end

  defp normalize(%{status: :pending} = state), do: state

  defp normalize(state) do
    cond do
      authenticated?() -> terminal(state, :completed)
      state.status == :completed -> terminal(state, :idle)
      true -> state
    end
  end

  defp terminal(state, status, error \\ nil) do
    cancel_timer(state.timer)

    %{
      state
      | status: status,
        helper_ref: nil,
        device: nil,
        deadline: nil,
        timer: nil,
        error: error
    }
  end

  defp reply_waiters(state) do
    response = {:ok, snapshot(state)}
    Enum.each(state.waiters, &GenServer.reply(&1, response))
    %{state | waiters: []}
  end

  defp snapshot(state) do
    base = %{provider: @provider, authenticated: authenticated?(), status: state.status}

    base =
      case state.device do
        nil ->
          base

        device ->
          Map.merge(base, %{
            verification_url: device.verification_url,
            user_code: device.user_code,
            expires_in_seconds: remaining_seconds(state.deadline)
          })
      end

    if state.error, do: Map.put(base, :error, state.error), else: base
  end

  defp authenticated? do
    with {:ok, contents} <- File.read(PiInstallation.auth_path()),
         {:ok, data} when is_map(data) <- JSON.decode(contents),
         %{
           "type" => "oauth",
           "access" => access,
           "refresh" => refresh,
           "expires" => expires
         }
         when is_binary(access) and access != "" and is_binary(refresh) and refresh != "" and
                is_number(expires) <- Map.get(data, @provider) do
      true
    else
      _missing_or_invalid -> false
    end
  end

  defp helper, do: Utils.module(:codex_auth_helper)

  defp stop_helper(nil), do: :ok

  defp stop_helper(ref) do
    case helper().stop(ref) do
      :ok ->
        :ok

      {:error, :not_found} ->
        :ok

      {:error, reason} ->
        Logger.warning("Pi Codex OAuth helper could not be stopped: #{safe_reason(reason)}")
    end
  end

  defp configured_startup_timeout do
    :rinto_pmo
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:startup_timeout, @default_startup_timeout)
  end

  defp deadline(timeout), do: System.monotonic_time(:millisecond) + timeout

  defp remaining_seconds(nil), do: 0

  defp remaining_seconds(deadline) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)
    Integer.ceil_div(remaining, 1_000)
  end

  defp cancel_timer(nil), do: :ok
  defp cancel_timer(timer), do: Process.cancel_timer(timer, async: true, info: false)

  defp safe_code(code) when code in ["auth_failed", "auth_cancelled", "pi_sdk_unavailable"],
    do: code

  defp safe_code(_unknown), do: "auth_failed"

  defp sanitize_diagnostic(line) do
    line
    |> String.trim()
    |> String.slice(0, 500)
    |> String.replace(~r/\b(?:eyJ|sk-)[A-Za-z0-9._~-]{12,}\b/u, "[redacted]")
    |> String.replace(
      ~r/(access|refresh|authorization)[_-]?(token|code)\s*[:=]\s*\S+/iu,
      "[redacted]"
    )
  end

  defp safe_reason(reason) do
    reason
    |> inspect(limit: 10, printable_limit: 300)
    |> sanitize_diagnostic()
  end
end
