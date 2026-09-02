defmodule RintoPMO.Agent.CodexAuth.Helper do
  @moduledoc """
  Starts the Node/Bun bridge which calls Pi's public `ModelRuntime` auth API.

  The bridge receives the resolved Pi executable, not a package name. It then
  imports the SDK entry point belonging to that executable's package, which is
  what keeps Pi RPC and OAuth on the same installed version.
  """

  alias RintoPMO.Agent.CodexAuth.Parser
  alias RintoPMO.Agent.PiInstallation
  alias RintoPMO.OSProcess

  @type ref :: OSProcess.id()

  defmodule Behaviour do
    @moduledoc false

    @callback start_login(pid(), keyword()) :: {:ok, term()} | {:error, term()}
    @callback stop(term()) :: :ok | {:error, term()}
    @callback logout(keyword()) :: :ok | {:error, term()}
  end

  @behaviour Behaviour

  @impl Behaviour
  def start_login(owner, opts) when is_pid(owner) do
    with {:ok, command} <- command("login", opts) do
      id = "pi-codex-auth-#{System.unique_integer([:positive, :monotonic])}"

      case OSProcess.start(
             id: id,
             cmd: command.runtime,
             args: command.args,
             env: PiInstallation.environment(),
             owner: owner,
             framing: :lines,
             stderr: :owner,
             max_line_bytes: 16_384
           ) do
        {:ok, _pid} -> {:ok, id}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @impl Behaviour
  def stop(ref), do: OSProcess.stop(ref)

  @impl Behaviour
  def logout(opts) do
    timeout = Keyword.get(opts, :timeout, 30_000)

    with {:ok, command} <- command("logout", opts),
         {:ok, result} <-
           OSProcess.run(
             cmd: command.runtime,
             args: command.args,
             env: PiInstallation.environment(),
             stderr: :owner,
             max_line_bytes: 16_384,
             timeout: timeout
           ) do
      completed(result)
    end
  end

  defp command(action, opts) do
    with {:ok, pi_executable} <- PiInstallation.executable_path(),
         {:ok, runtime} <- runtime(pi_executable),
         {:ok, script} <- script_path() do
      auth_path = Keyword.get(opts, :auth_path, PiInstallation.auth_path())

      {:ok,
       %{
         runtime: runtime,
         args: [
           script,
           "--action",
           action,
           "--pi-executable",
           pi_executable,
           "--auth-path",
           auth_path
         ]
       }}
    end
  end

  # Pi's recommended npm installation is a JavaScript launcher with an env
  # shebang. Bun installations may use the equivalent Bun launcher. Prefer the
  # interpreter named by that launcher, then fall back to either supported
  # runtime so custom-but-compatible package manager layouts still work.
  defp runtime(pi_executable) do
    requested = Application.get_env(:rinto_pmo, :pi_auth_helper_runtime)

    candidates =
      [requested, shebang_runtime(pi_executable), "node", "bun"]
      |> Enum.filter(&(is_binary(&1) and &1 != ""))
      |> Enum.uniq()

    case Enum.find_value(candidates, &System.find_executable/1) do
      nil -> {:error, :helper_runtime_not_found}
      path -> {:ok, path}
    end
  end

  defp shebang_runtime(pi_executable) do
    with {:ok, file} <- File.open(pi_executable, [:read]),
         line when is_binary(line) <- IO.read(file, :line) do
      File.close(file)

      cond do
        String.contains?(line, "bun") -> "bun"
        String.contains?(line, "node") -> "node"
        true -> nil
      end
    else
      _unreadable -> nil
    end
  end

  defp script_path do
    case :code.priv_dir(:rinto_pmo) do
      {:error, _reason} -> {:error, :helper_script_not_found}
      dir -> {:ok, Path.join(to_string(dir), "pi_auth_helper.mjs")}
    end
  end

  defp completed(%{status: {:exit, 0}, stdout: stdout}) do
    stdout
    |> String.split("\n", trim: true)
    |> Enum.reduce_while({:error, :invalid_helper_output}, fn line, _acc ->
      case Parser.parse(line) do
        {:ok, :completed} -> {:halt, :ok}
        {:ok, {:error, code, _message}} -> {:halt, {:error, {:helper_error, code}}}
        _other -> {:halt, {:error, :invalid_helper_output}}
      end
    end)
  end

  defp completed(%{status: status}), do: {:error, {:helper_exit, status}}
end
