defmodule RintoPMO.Agent.PiInstallation do
  @moduledoc """
  Resolves the Pi installation and credential location shared by every Pi
  process started by this application.

  Pi itself uses `PI_CODING_AGENT_DIR` when present and otherwise
  `$HOME/.pi/agent`. Keeping that resolution here gives the OAuth helper the
  exact same inputs as `pi --mode rpc` without guessing an npm package name or
  a global package-manager prefix.
  """

  @default_agent_dir Path.join([".pi", "agent"])

  @spec executable() :: String.t()
  def executable, do: Application.get_env(:rinto_pmo, :pi_executable, "pi")

  @spec executable_path() :: {:ok, Path.t()} | {:error, :pi_not_found}
  def executable_path do
    case System.find_executable(executable()) do
      nil -> {:error, :pi_not_found}
      path -> {:ok, path}
    end
  end

  @spec agent_dir() :: Path.t()
  def agent_dir do
    configured = Application.get_env(:rinto_pmo, :pi_agent_dir)

    cond do
      present?(configured) ->
        Path.expand(configured)

      present?(System.get_env("PI_CODING_AGENT_DIR")) ->
        expand(System.get_env("PI_CODING_AGENT_DIR"))

      true ->
        Path.join(home(), @default_agent_dir)
    end
  end

  @spec auth_path() :: Path.t()
  def auth_path, do: Path.join(agent_dir(), "auth.json")

  @spec environment([RintoPMO.OSProcess.env_entry()]) :: [RintoPMO.OSProcess.env_entry()]
  def environment(extra \\ []) do
    fixed_names = ["HOME", "PI_CODING_AGENT_DIR"]
    extra = Enum.reject(extra, fn {name, _value} -> name in fixed_names end)
    extra ++ [{"HOME", home()}, {"PI_CODING_AGENT_DIR", agent_dir()}]
  end

  defp home do
    case System.get_env("HOME") do
      value when is_binary(value) and value != "" -> Path.expand(value)
      _absent -> System.user_home!()
    end
  end

  defp expand("~/" <> rest), do: Path.join(home(), rest)
  defp expand(path), do: Path.expand(path)

  defp present?(value), do: is_binary(value) and String.trim(value) != ""
end
