defmodule RintoPMO.OSProcess.Spec do
  @moduledoc false

  # Validated launch parameters for a single OS process.
  #
  # `new/1` runs in the *caller's* process, before the instance is started, so
  # that `:owner` defaults to the caller rather than the DynamicSupervisor and
  # so that bad options come back as plain tagged tuples instead of a
  # supervisor crash report.

  import Bitwise, only: [&&&: 2]

  @enforce_keys [
    :id,
    :argv,
    :owner,
    :framing,
    :max_line_bytes,
    :kill_timeout,
    :drain_timeout,
    :exec_opts
  ]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          id: RintoPMO.OSProcess.id(),
          argv: [binary()],
          owner: pid(),
          framing: RintoPMO.OSProcess.framing(),
          max_line_bytes: pos_integer() | :infinity,
          kill_timeout: pos_integer(),
          drain_timeout: non_neg_integer(),
          exec_opts: [term()]
        }

  @framings [:raw, :lines]
  @stderr_modes [:owner, :stdout, :discard]

  @default_kill_timeout 5
  @default_drain_timeout 25
  @default_max_line_bytes :infinity

  @doc """
  Validates start options and precomputes the erlexec option list.
  """
  @spec new(keyword()) :: {:ok, t()} | {:error, RintoPMO.OSProcess.start_error()}
  def new(opts) when is_list(opts) do
    with {:ok, id} <- fetch_id(opts),
         {:ok, argv} <- fetch_argv(opts),
         {:ok, owner} <- fetch_owner(opts),
         {:ok, framing} <- fetch_enum(opts, :framing, @framings, :raw),
         {:ok, stderr} <- fetch_enum(opts, :stderr, @stderr_modes, :owner),
         {:ok, cd} <- fetch_cd(opts),
         {:ok, env} <- fetch_env(opts),
         {:ok, max_line_bytes} <- fetch_max_line_bytes(opts),
         {:ok, kill_timeout} <- fetch_pos_integer(opts, :kill_timeout, default(:kill_timeout)),
         {:ok, drain_timeout} <-
           fetch_non_neg_integer(opts, :drain_timeout, default(:drain_timeout)),
         {:ok, kill_group?} <- fetch_boolean(opts, :kill_group, true) do
      {:ok,
       %__MODULE__{
         id: id,
         argv: argv,
         owner: owner,
         framing: framing,
         max_line_bytes: max_line_bytes,
         kill_timeout: kill_timeout,
         drain_timeout: drain_timeout,
         exec_opts:
           build_exec_opts(%{
             stderr: stderr,
             cd: cd,
             env: env,
             kill_timeout: kill_timeout,
             kill_group?: kill_group?
           })
       }}
    end
  end

  @doc """
  Milliseconds a supervisor should wait for the instance to shut down.

  Covers erlexec's SIGTERM/SIGKILL grace plus slack for the reap round trip.
  """
  @spec shutdown_timeout(t()) :: pos_integer()
  def shutdown_timeout(%__MODULE__{kill_timeout: kill_timeout}),
    do: kill_timeout * 1_000 + 2_000

  @doc """
  Milliseconds `terminate/2` may spend waiting for the OS process to be reaped.

  Deliberately shorter than `shutdown_timeout/1`: the difference is the slack
  in which `terminate/2` still gets to deliver the final exit event before a
  supervisor gives up waiting and brutally kills the instance.
  """
  @spec reap_timeout(t()) :: pos_integer()
  def reap_timeout(%__MODULE__{} = spec), do: shutdown_timeout(spec) - 1_000

  # An absent `:id` is filled in here rather than rejected: one-shot callers
  # address the instance by pid and never need to invent a name.
  defp fetch_id(opts) do
    case Keyword.fetch(opts, :id) do
      {:ok, id} when is_binary(id) and id != "" -> {:ok, id}
      {:ok, other} -> {:error, {:invalid_option, :id, other}}
      :error -> {:ok, generate_id()}
    end
  end

  defp generate_id, do: "osproc-#{System.unique_integer([:positive, :monotonic])}"

  defp fetch_argv(opts) do
    with {:ok, cmd} <- fetch_cmd(opts),
         {:ok, args} <- fetch_args(opts),
         {:ok, path} <- resolve_executable(cmd) do
      {:ok, [path | args]}
    end
  end

  defp fetch_cmd(opts) do
    case Keyword.fetch(opts, :cmd) do
      {:ok, cmd} when is_binary(cmd) and cmd != "" -> {:ok, cmd}
      {:ok, other} -> {:error, {:invalid_option, :cmd, other}}
      :error -> {:error, {:missing_option, :cmd}}
    end
  end

  defp fetch_args(opts) do
    args = Keyword.get(opts, :args, [])

    if is_list(args) and Enum.all?(args, &is_binary/1) do
      {:ok, args}
    else
      {:error, {:invalid_option, :args, args}}
    end
  end

  # An absolute or relative path is used verbatim; a bare name is resolved
  # against PATH (System.find_executable/1 already checks the mode bits).
  # Pre-flighting here turns erlexec's opaque spawn failure into a clear error
  # before any process is started.
  defp resolve_executable(cmd) do
    cond do
      String.contains?(cmd, "/") -> validate_executable(cmd)
      path = System.find_executable(cmd) -> {:ok, path}
      true -> {:error, {:executable_not_found, cmd}}
    end
  end

  # Checking only File.regular?/1 would let a non-executable file through and
  # defer the failure to erlexec, where it surfaces as an opaque spawn error --
  # exactly what pre-flighting is meant to avoid.
  defp validate_executable(path) do
    case File.stat(path) do
      {:ok, %File.Stat{type: :regular, mode: mode}} when (mode &&& 0o111) != 0 -> {:ok, path}
      _other -> {:error, {:executable_not_found, path}}
    end
  end

  # A registered name is resolved to a pid here so that everything downstream --
  # monitoring, DOWN handling, event delivery -- stays uniformly pid-based.
  defp fetch_owner(opts) do
    case Keyword.get(opts, :owner, self()) do
      owner when is_pid(owner) ->
        {:ok, owner}

      name when is_atom(name) and not is_nil(name) and not is_boolean(name) ->
        case Process.whereis(name) do
          nil -> {:error, {:invalid_option, :owner, name}}
          pid -> {:ok, pid}
        end

      other ->
        {:error, {:invalid_option, :owner, other}}
    end
  end

  defp fetch_enum(opts, key, allowed, default) do
    value = Keyword.get(opts, key, default)

    if value in allowed do
      {:ok, value}
    else
      {:error, {:invalid_option, key, value}}
    end
  end

  defp fetch_cd(opts) do
    case Keyword.fetch(opts, :cd) do
      :error -> {:ok, nil}
      {:ok, dir} when is_binary(dir) -> validate_dir(dir)
      {:ok, other} -> {:error, {:invalid_option, :cd, other}}
    end
  end

  defp validate_dir(dir) do
    if File.dir?(dir) do
      {:ok, dir}
    else
      {:error, {:invalid_option, :cd, dir}}
    end
  end

  defp fetch_env(opts) do
    case Keyword.fetch(opts, :env) do
      :error ->
        {:ok, nil}

      {:ok, env} when is_list(env) ->
        if Enum.all?(env, &env_entry?/1) do
          {:ok, env}
        else
          {:error, {:invalid_option, :env, env}}
        end

      {:ok, other} ->
        {:error, {:invalid_option, :env, other}}
    end
  end

  # erlexec accepts `{name, false}` to unset a single inherited variable and a
  # bare `:clear` to start from an empty environment; both are passed straight
  # through (deps/erlexec/src/exec.erl, parse_env/1).
  defp env_entry?(:clear), do: true
  defp env_entry?({name, false}) when is_binary(name), do: true
  defp env_entry?({name, value}) when is_binary(name) and is_binary(value), do: true
  defp env_entry?(_other), do: false

  defp fetch_max_line_bytes(opts) do
    case Keyword.get(opts, :max_line_bytes, default(:max_line_bytes)) do
      :infinity -> {:ok, :infinity}
      value when is_integer(value) and value > 0 -> {:ok, value}
      other -> {:error, {:invalid_option, :max_line_bytes, other}}
    end
  end

  defp fetch_pos_integer(opts, key, default) do
    case Keyword.get(opts, key, default) do
      value when is_integer(value) and value > 0 -> {:ok, value}
      other -> {:error, {:invalid_option, key, other}}
    end
  end

  defp fetch_non_neg_integer(opts, key, default) do
    case Keyword.get(opts, key, default) do
      value when is_integer(value) and value >= 0 -> {:ok, value}
      other -> {:error, {:invalid_option, key, other}}
    end
  end

  defp fetch_boolean(opts, key, default) do
    case Keyword.get(opts, key, default) do
      value when is_boolean(value) -> {:ok, value}
      other -> {:error, {:invalid_option, key, other}}
    end
  end

  # `:stdout` and `:stderr` as bare atoms mean "send to the process calling
  # :exec.run", which is the instance. `:link` is what makes erlexec reap the
  # OS process if the instance dies -- see RintoPMO.OSProcess docs.
  defp build_exec_opts(%{} = config) do
    [:stdin, :stdout, :link, {:kill_timeout, config.kill_timeout}]
    |> add_stderr(config.stderr)
    |> add_kill_group(config.kill_group?)
    |> add_pair(:cd, config.cd)
    |> add_pair(:env, config.env)
  end

  # `kill_group` makes erlexec signal `-getpgid(child)`. erlexec only calls
  # setpgid() when a `group` option is present (c_src/exec_impl.cpp:900), so
  # without one the child stays in exec-port's own process group and killing
  # the group takes down exec-port -- and with it every other instance.
  # `{group, 0}` puts the child in a process group of its own, which is what
  # makes group signalling safe.
  defp add_kill_group(opts, false), do: opts
  defp add_kill_group(opts, true), do: [:kill_group, {:group, 0} | opts]

  defp add_stderr(opts, :owner), do: [:stderr | opts]
  defp add_stderr(opts, :stdout), do: [{:stderr, :stdout} | opts]
  defp add_stderr(opts, :discard), do: [{:stderr, :null} | opts]

  defp add_pair(opts, _key, nil), do: opts
  defp add_pair(opts, key, value), do: [{key, value} | opts]

  defp default(key) do
    :rinto_pmo
    |> Application.get_env(RintoPMO.OSProcess, [])
    |> Keyword.get(key, hardcoded_default(key))
  end

  defp hardcoded_default(:kill_timeout), do: @default_kill_timeout
  defp hardcoded_default(:drain_timeout), do: @default_drain_timeout
  defp hardcoded_default(:max_line_bytes), do: @default_max_line_bytes
end
