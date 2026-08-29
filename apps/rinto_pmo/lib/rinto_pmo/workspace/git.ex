defmodule RintoPMO.Workspace.Git do
  @moduledoc """
  Every git invocation this system makes, and the only place a credential is
  handed to one.

  ## The token never reaches the disk

  `git clone https://user:token@host/repo` writes the credential verbatim into
  `.git/config`, and that file sits inside a directory pi is given to read. It
  could then copy the token into a document. So the URL carries the username
  only -- which is not secret -- and the token arrives through `GIT_ASKPASS`,
  read from the environment of one short-lived child process.

  The askpass script itself holds no secret: it echoes a variable that only a
  git process started here is given. See `RintoPMO.Workspace.ensure_askpass/1`.

  `GIT_TERMINAL_PROMPT=0` so a missing credential fails instead of parking on a
  prompt no one will ever answer, and `GIT_CONFIG_NOSYSTEM=1` so a system-wide
  `credential.helper` cannot quietly cache what we deliberately did not store.

  ## Discovery is fenced

  `git -C <dir>` does not fail when `<dir>` is not a repository: git walks up
  the directory tree and uses the first repository it finds. A worktree that
  lost its `.git` link therefore turns `reset --hard` into a hard reset of
  whatever repository happens to be above the workspace root -- which, if the
  root is inside a checkout, is somebody's working tree.

  Every invocation carries `GIT_CEILING_DIRECTORIES`, so discovery stops at the
  workspace root and a directory that is not a repository fails as one.
  Callers check that a worktree is intact before driving it; this is the fence
  behind that check, not a substitute for it.

  ## Failure is data

  Nothing here raises. A non-zero exit, a timeout and a missing executable are
  all values, because every one of them ends up as text in
  `project_repos.last_sync_error` and, from there, in front of pi.
  """

  alias RintoPMO.OSProcess

  @default_timeout 15_000

  # Long enough to diagnose, short enough that a repository whose remote
  # answers with a wall of text cannot fill a database column with it.
  @max_output_bytes 2_000

  @typedoc """
  A credential to hand to git, or `nil` for an anonymous remote.
  """
  @type credential :: %{username: String.t(), token: String.t()} | nil

  @type error ::
          {:git, %{argv: [String.t()], status: term(), output: String.t()}}
          | {:timeout, %{argv: [String.t()], output: String.t()}}
          | {:unavailable, term()}

  @type opt ::
          {:timeout, timeout()}
          | {:credential, credential()}
          | {:askpass, Path.t() | nil}
          | {:ceiling, Path.t() | nil}

  @doc """
  Runs one git command and returns its output.

  Options:

    * `:timeout` - milliseconds, default #{@default_timeout}
    * `:credential` - `%{username: _, token: _}`, or `nil`
    * `:askpass` - path to the askpass script; required when a credential is given
    * `:ceiling` - absolute path repository discovery may not climb above
  """
  @spec run([String.t()], [opt()]) :: {:ok, String.t()} | {:error, error()}
  def run(args, opts \\ []) when is_list(args) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)

    env =
      environment(
        Keyword.get(opts, :credential),
        Keyword.get(opts, :askpass),
        Keyword.get(opts, :ceiling)
      )

    case OSProcess.run(cmd: "git", args: args, env: env, stderr: :stdout, timeout: timeout) do
      {:ok, %{status: {:exit, 0}, stdout: output}} ->
        {:ok, output}

      {:ok, %{status: status, stdout: output}} ->
        {:error, {:git, %{argv: args, status: status, output: truncate(output)}}}

      {:error, {:timeout, partial}} ->
        {:error, {:timeout, %{argv: args, output: truncate(partial.stdout)}}}

      {:error, reason} ->
        {:error, {:unavailable, reason}}
    end
  end

  @doc """
  A one-line description of a failure, for `project_repos.last_sync_error`.

  Written for whoever reads it in a conversation, so it names the operation
  rather than the whole argv: the caller knows which repository it asked about,
  and the full command line is noise around the one line of git's own output
  that says what went wrong.
  """
  @spec describe(error()) :: String.t()
  def describe({:git, %{argv: argv, status: {:exit, code}, output: output}}),
    do: "#{operation(argv)} failed (exit #{code}): #{first_line(output)}"

  def describe({:git, %{argv: argv, status: status, output: output}}),
    do: "#{operation(argv)} failed (#{inspect(status)}): #{first_line(output)}"

  def describe({:timeout, %{argv: argv}}),
    do: "#{operation(argv)} timed out"

  def describe({:unavailable, {:executable_not_found, cmd}}),
    do: "#{cmd} is not installed on this machine"

  def describe({:unavailable, reason}),
    do: "git could not be started: #{inspect(reason)}"

  # `git -C <dir> fetch --prune` is "fetch". The subcommand is the first
  # argument that is neither a flag nor the value of `-C`/`-c`.
  defp operation(argv), do: argv |> subcommand() |> then(&"git #{&1}")

  defp subcommand(["-C", _dir | rest]), do: subcommand(rest)
  defp subcommand(["-c", _setting | rest]), do: subcommand(rest)
  defp subcommand(["--" <> _flag | rest]), do: subcommand(rest)
  defp subcommand([word | _rest]), do: word
  defp subcommand([]), do: "command"

  defp first_line(""), do: "no output"

  defp first_line(output) do
    output
    |> String.split("\n", trim: true)
    |> Enum.reject(&(String.trim(&1) == ""))
    |> List.last()
    |> Kernel.||("no output")
    |> String.trim()
  end

  defp truncate(output) when byte_size(output) <= @max_output_bytes, do: output
  defp truncate(output), do: binary_part(output, 0, @max_output_bytes) <> "\n[truncated]"

  defp environment(credential, askpass, ceiling) do
    base = [{"GIT_TERMINAL_PROMPT", "0"}, {"GIT_CONFIG_NOSYSTEM", "1"} | ceiling(ceiling)]

    case credential do
      %{token: token} when is_binary(askpass) ->
        [{"GIT_ASKPASS", askpass}, {"RINTO_GIT_PASSWORD", token} | base]

      _anonymous ->
        base
    end
  end

  # Best effort, and only ever that: git compares the ceiling against the path
  # it reaches after resolving symlinks, so a root reached through one would
  # not match and discovery would climb past it. What actually keeps a broken
  # worktree from being driven as somebody else's repository is the caller
  # checking that it is one first -- see `RintoPMO.Workspace`.
  defp ceiling(nil), do: []
  defp ceiling(path), do: [{"GIT_CEILING_DIRECTORIES", path}]
end
