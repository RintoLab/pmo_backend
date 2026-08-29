defmodule RintoPMO.Workspace do
  @moduledoc """
  The on-disk copies of the repositories registered in `project_repos`, kept so
  that the agent answering questions about a project can read its code.

  This is the "future synchronization subsystem"
  `RintoPMO.Projects.ProjectRepo` refers to: it owns `last_synced_at` and
  `last_sync_error`, and it is the only thing that writes them.

  ## Off unless configured

  With no `:root` configured there is no workspace and every call answers
  `{:error, :not_configured}`. An installation that does not want an agent
  reading code is not a broken one, so nothing warns and nothing fails to boot.

  ## One mirror per repository, one worktree per branch

      <root>/<project-slug>/<repo-name>/.mirror/        the only thing that talks to the network
      <root>/<project-slug>/<repo-name>/worktrees/main/
      <root>/<project-slug>/<repo-name>/worktrees/feat/x/

  A single checkout that switched branches would let two conversations tread on
  each other: one asks about `main`, the other switches to a topic branch, and
  the first reads the second's files without any way to notice -- the directory
  looks identical either way. Worktrees off a shared mirror cost one clone and
  make that impossible.

  Nothing ever writes in a worktree, so `reset --hard` cannot hit a conflict.
  That is the whole reason updating is a single unconditional command rather
  than a merge with a failure mode.

  ## Freshness is lazy

  A fetch happens when somebody asks for a checkout and the last one was longer
  ago than `:ttl_ms`. There is no timer and no background poll: a project no one
  is discussing costs nothing. The TTL exists because a repository may live on
  the public internet, where even a fetch that finds nothing costs a round trip.

  ## Worktrees are swept, not kept

  A worktree nobody has asked about in `:worktree_retention_ms` is removed on
  the way out of the next checkout of that repository. There is no timer here
  either: a branch is rebuilt by one local `worktree add`, so keeping one costs
  more than losing one.

  What counts as "asked about" is recorded rather than inferred -- see
  `stamp/1`. git cannot answer it: worktrees here are detached, and
  `worktree list` reports a commit and a path but never a branch.

  ## A failed fetch is reported, not fatal

  If the mirror already exists, a fetch that fails leaves the previous snapshot
  in place, records why in `last_sync_error`, and still hands back a checkout --
  with `:sync_error` set, so the caller can say the code it is looking at is
  stale rather than present it as current. Only a repository that has never been
  cloned has nothing to fall back to.
  """

  use RintoPMO, :context

  alias RintoPMO.Projects.Project
  alias RintoPMO.Projects.ProjectRepo
  alias RintoPMO.Workspace.Git
  alias RintoPMO.Workspace.Server

  # Both a path component and a git argument, so: no leading dash (which git
  # would read as a flag), and no component that could climb out of the root.
  # Requiring an alphanumeric first character settles all of it at once --
  # `..`, `.git` and `-oops` are the same rejection.
  @segment ~r{\A[A-Za-z0-9][A-Za-z0-9._-]*\z}
  @branch ~r{\A[A-Za-z0-9][A-Za-z0-9._/-]*\z}
  @max_branch_bytes 200

  # Any URL git will not dial. A read-only token is an agreement with whoever
  # issued it; refusing to push is the part the machine itself can guarantee.
  @no_push "rinto://refuses-to-push"

  @askpass """
  #!/bin/sh
  # Written by RintoPMO.Workspace. This file holds no secret: it echoes a
  # variable that only a git process started by this system is given.
  printf '%s\\n' "${RINTO_GIT_PASSWORD}"
  """

  @typedoc """
  Where a branch is on disk, and how current it is.

  `synced_at` is when the mirror last reached the remote successfully, which is
  `nil` for a repository that has never been fetched. `sync_error` is set when
  this checkout was served from a snapshot that could not be refreshed.
  """
  @type checkout :: %{
          path: Path.t(),
          branch: String.t(),
          commit: String.t(),
          synced_at: DateTime.t() | nil,
          sync_error: String.t() | nil
        }

  @type error ::
          :not_configured
          | {:invalid_name, String.t()}
          | {:invalid_branch, String.t()}
          | {:unknown_branch, String.t()}
          | {:root_unavailable, term()}
          | {:git, Git.error()}

  @type opt :: {:branch, String.t() | nil} | {:force, boolean()}

  defmodule Behaviour do
    @moduledoc false

    alias RintoPMO.Projects.Project
    alias RintoPMO.Projects.ProjectRepo

    @callback checkout(Project.t(), ProjectRepo.t(), [RintoPMO.Workspace.opt()]) ::
                {:ok, RintoPMO.Workspace.checkout()} | {:error, RintoPMO.Workspace.error()}
  end

  @behaviour Behaviour

  @doc """
  Whether this installation has a workspace at all.
  """
  @spec configured?() :: boolean()
  def configured?, do: root() != nil

  @doc """
  The configured workspace root, or `nil`.
  """
  @spec root() :: Path.t() | nil
  def root do
    case setting(:root) do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> nil
          trimmed -> Path.expand(trimmed)
        end

      _unset ->
        nil
    end
  end

  @doc """
  Makes a branch of a repository available on disk and says where it is.

  Serialised against every other checkout: two conversations asking about the
  same repository must not run git in the same directory at the same time, and
  a single queue is enough for the number of repositories one installation has.

  Options:

    * `:branch` - defaults to the repository's own `branch`
    * `:force` - fetch even if the last one was within the TTL
  """
  @impl Behaviour
  @spec checkout(Project.t(), ProjectRepo.t(), [opt()]) ::
          {:ok, checkout()} | {:error, error()}
  def checkout(%Project{} = project, %ProjectRepo{} = repo, opts) do
    Server.checkout(project, repo, opts)
  end

  @doc """
  Brings a repository's own branch up to date, by id.

  What `RintoPMO.Workspace.SyncWorker` runs when a repository is registered.
  Answers `:ok` for a repository that has since been deleted: the job outliving
  its subject is not a failure, and there is nothing left to clone.
  """
  @spec sync(UUIDv7.t()) :: :ok | {:error, error()}
  def sync(project_repo_id) when is_binary(project_repo_id) do
    ProjectRepo
    |> Repo.get(project_repo_id)
    |> Repo.preload(:project)
    |> case do
      nil ->
        :ok

      %ProjectRepo{project: project} = repo ->
        case checkout(project, repo, force: true) do
          {:ok, _checkout} -> :ok
          {:error, reason} -> {:error, reason}
        end
    end
  end

  @doc false
  # The body of `checkout/3`, called by the server that serialises it. Public
  # only so that tests can drive it without a queue in the way.
  @spec perform_checkout(Project.t(), ProjectRepo.t(), [opt()]) ::
          {:ok, checkout()} | {:error, error()}
  def perform_checkout(%Project{} = project, %ProjectRepo{} = repo, opts \\ []) do
    with {:ok, root} <- ensure_root(),
         {:ok, slug} <- validate_segment(project.slug),
         {:ok, name} <- validate_segment(repo.name),
         {:ok, branch} <- validate_branch(Keyword.get(opts, :branch) || repo.branch),
         {:ok, askpass} <- ensure_askpass(root) do
      repo = Repo.preload(repo, :credential)
      mirror = Path.join([root, slug, name, ".mirror"])
      worktrees = Path.join([root, slug, name, "worktrees"])
      worktree = Path.join([worktrees | Path.split(branch)])

      context = %{
        repo: repo,
        mirror: mirror,
        worktrees: worktrees,
        askpass: askpass,
        root: root
      }

      with {:ok, repo} <- ensure_mirror(context),
           {:ok, repo} <- refresh(%{context | repo: repo}, Keyword.get(opts, :force, false)),
           {:ok, commit} <- resolve(context, branch),
           {:ok, path} <- ensure_worktree(context, worktree, branch) do
        # In that order: the one just asked for is stamped before anything is
        # judged old, so it can never be swept by the same call that made it.
        stamp(path)
        sweep(context, path)

        {:ok,
         %{
           path: path,
           branch: branch,
           commit: commit,
           synced_at: repo.last_synced_at,
           sync_error: repo.last_sync_error
         }}
      end
    end
  end

  @doc """
  Writes the askpass script under the root, and returns its path.

  Idempotent, and rewritten every time rather than compared first: it is a
  deploy artifact of this module, nobody edits it, and "install it" has no
  second branch to get wrong.
  """
  @spec ensure_askpass(Path.t()) :: {:ok, Path.t()} | {:error, error()}
  def ensure_askpass(root) do
    path = Path.join(root, ".askpass")

    with :ok <- File.write(path, @askpass),
         :ok <- File.chmod(path, 0o700) do
      {:ok, path}
    else
      {:error, reason} -> {:error, {:root_unavailable, reason}}
    end
  end

  ## Mirror

  defp ensure_mirror(%{mirror: mirror, repo: repo} = context) do
    if File.dir?(mirror) do
      {:ok, repo}
    else
      case File.mkdir_p(Path.dirname(mirror)) do
        :ok -> clone(context)
        {:error, reason} -> {:error, {:root_unavailable, reason}}
      end
    end
  end

  # A first clone has nothing to fall back to, so unlike a fetch its failure is
  # the caller's failure. The reason is still recorded: whoever registered the
  # repository with the wrong credential should be able to see that from the
  # API rather than from a conversation going wrong later.
  defp clone(%{mirror: mirror, repo: repo} = context) do
    args = ["clone", "--mirror", remote_url(repo), mirror]

    case Git.run(args, git_opts(context, setting(:clone_timeout))) do
      {:ok, _output} ->
        configure_remote(context)
        record_success(repo)

      {:error, reason} ->
        _ = File.rm_rf(mirror)
        {:ok, _repo} = record_failure(repo, Git.describe(reason))
        {:error, {:git, reason}}
    end
  end

  defp refresh(%{repo: repo} = context, force?) do
    if force? or stale?(repo) do
      fetch(context)
    else
      {:ok, repo}
    end
  end

  defp fetch(%{mirror: mirror, repo: repo} = context) do
    configure_remote(context)

    case Git.run(
           ["-C", mirror, "fetch", "--prune", "origin"],
           git_opts(context, setting(:fetch_timeout))
         ) do
      {:ok, _output} -> record_success(repo)
      {:error, reason} -> record_failure(repo, Git.describe(reason))
    end
  end

  # Run before every fetch rather than once at clone time, so a credential's
  # username changed in the database reaches the remote this time rather than
  # next time.
  defp configure_remote(%{mirror: mirror, repo: repo} = context) do
    opts = local_opts(context)
    _ = Git.run(["-C", mirror, "remote", "set-url", "origin", remote_url(repo)], opts)
    _ = Git.run(["-C", mirror, "config", "remote.origin.pushurl", @no_push], opts)
    :ok
  end

  defp stale?(%ProjectRepo{last_synced_at: nil}), do: true

  defp stale?(%ProjectRepo{last_synced_at: at}),
    do: DateTime.diff(DateTime.utc_now(), at, :millisecond) >= setting(:ttl_ms)

  ## Worktree

  defp resolve(%{mirror: mirror} = context, branch) do
    args = ["-C", mirror, "rev-parse", "--verify", "--quiet", "refs/heads/#{branch}^{commit}"]

    case Git.run(args, local_opts(context)) do
      {:ok, output} ->
        case String.trim(output) do
          "" -> {:error, {:unknown_branch, branch}}
          commit -> {:ok, commit}
        end

      {:error, {:git, %{status: {:exit, 1}}}} ->
        {:error, {:unknown_branch, branch}}

      {:error, reason} ->
        {:error, {:git, reason}}
    end
  end

  defp ensure_worktree(%{mirror: mirror} = context, path, branch) do
    cond do
      not File.dir?(path) ->
        add_worktree(context, path, branch)

      # `git -C <dir>` does not fail when `<dir>` is not a repository: it walks
      # up and uses the first one it finds. A worktree that lost its `.git`
      # link would therefore hard-reset whatever repository sits above the
      # workspace root. Proving this one belongs to our mirror before touching
      # it is what makes that impossible; nothing here may rely on git failing.
      not worktree_of?(path, mirror) ->
        recreate_worktree(context, path, branch)

      true ->
        case Git.run(["-C", path, "reset", "--hard", "refs/heads/#{branch}"], local_opts(context)) do
          {:ok, _output} -> {:ok, path}
          # Intact enough to identify, not enough to drive. Nothing in there is
          # anybody's work, so it is cheaper to rebuild than to diagnose.
          {:error, _reason} -> recreate_worktree(context, path, branch)
        end
    end
  end

  # A linked worktree's `.git` is a file holding `gitdir: <path>`, and that path
  # points inside the repository the worktree belongs to.
  defp worktree_of?(path, mirror) do
    with {:ok, contents} <- File.read(Path.join(path, ".git")),
         "gitdir:" <> gitdir <- String.trim(contents) do
      gitdir
      |> String.trim()
      |> Path.expand(path)
      |> String.starts_with?(Path.expand(mirror) <> "/")
    else
      _not_ours -> false
    end
  end

  defp recreate_worktree(%{mirror: mirror} = context, path, branch) do
    opts = local_opts(context)
    _ = Git.run(["-C", mirror, "worktree", "remove", "--force", path], opts)
    _ = File.rm_rf(path)
    _ = Git.run(["-C", mirror, "worktree", "prune"], opts)
    add_worktree(context, path, branch)
  end

  # `--detach` is not a style choice. In a `--mirror` clone `refs/heads/*` are
  # the upstream's own refs, and git refuses to fetch into a branch that a
  # worktree has checked out:
  #
  #     fatal: refusing to fetch into branch 'refs/heads/main' checked out at ...
  #
  # So a worktree attached to its branch would break the next fetch of the whole
  # repository -- and only the *next* one, which is the kind of failure that
  # gets attributed to anything but the worktree that caused it. Detached, the
  # branch is only ever a starting point that `reset --hard` re-reads.
  defp add_worktree(%{mirror: mirror} = context, path, branch) do
    case File.mkdir_p(Path.dirname(path)) do
      :ok ->
        args = ["-C", mirror, "worktree", "add", "--detach", path, "refs/heads/#{branch}"]

        case Git.run(args, local_opts(context)) do
          {:ok, _output} -> {:ok, path}
          {:error, reason} -> {:error, {:git, reason}}
        end

      {:error, reason} ->
        {:error, {:root_unavailable, reason}}
    end
  end

  ## Sweeping

  # A worktree costs a working tree's worth of disk and is rebuilt by one local
  # `worktree add`, so keeping one nobody has asked about is the expensive side
  # of the trade. Swept on the way out of a checkout rather than on a timer, for
  # the same reason fetching is lazy: a repository nobody is discussing should
  # cost nothing at all.
  #
  # Nothing here can fail a checkout. The caller already has its answer, and a
  # directory that could not be removed is worth strictly less than the path it
  # would take down with it.
  defp sweep(%{mirror: mirror, worktrees: worktrees} = context, keep) do
    cutoff = System.os_time(:second) - div(setting(:worktree_retention_ms), 1_000)

    case Enum.filter(existing(worktrees), &(&1 != keep and last_used(&1) < cutoff)) do
      [] ->
        :ok

      stale ->
        Enum.each(stale, &File.rm_rf/1)
        _ = Git.run(["-C", mirror, "worktree", "prune"], local_opts(context))
        collect_empty(worktrees)
        :ok
    end
  rescue
    # File.stat on something that vanished mid-walk, a permission change, a
    # layout from an older version of this module. None of it is the caller's
    # problem, and all of it comes back next time.
    _error -> :ok
  end

  # Every worktree under `dir`, found by the `.git` file git leaves in each one.
  # git itself cannot answer this: `worktree list` reports a detached HEAD and a
  # path, never the branch, so which directory belongs to which branch is this
  # module's convention rather than something to ask about.
  defp existing(dir) do
    case File.ls(dir) do
      {:ok, entries} -> entries |> Enum.map(&Path.join(dir, &1)) |> Enum.flat_map(&under/1)
      {:error, _reason} -> []
    end
  end

  defp under(path) do
    cond do
      not File.dir?(path) -> []
      File.exists?(Path.join(path, ".git")) -> [path]
      # A branch name with a slash is a directory of worktrees.
      true -> existing(path)
    end
  end

  # Recorded rather than inferred: `reset --hard` on a worktree that is already
  # at the right commit changes nothing on disk, so a directory's own mtime says
  # when its contents last *changed*, not when anybody last asked for it. Only
  # the directory is touched -- a marker file inside a worktree would be read as
  # part of the project.
  defp stamp(path), do: File.touch(path)

  defp last_used(path) do
    case File.stat(path, time: :posix) do
      {:ok, %File.Stat{mtime: mtime}} -> mtime
      # Unreadable counts as fresh: refusing to judge is the safe direction,
      # because the mistake this makes is keeping something a little longer.
      {:error, _reason} -> System.os_time(:second)
    end
  end

  # The directories a nested branch name left behind. Deepest first, so
  # `feat/x` going away takes `feat/` with it in the same pass.
  defp collect_empty(dir) do
    case File.ls(dir) do
      {:ok, entries} -> Enum.each(entries, &collect_empty_child(Path.join(dir, &1)))
      {:error, _reason} -> :ok
    end
  end

  defp collect_empty_child(path) do
    if File.dir?(path) do
      collect_empty(path)
      if File.ls(path) == {:ok, []}, do: File.rmdir(path)
    end

    :ok
  end

  ## Recording

  defp record_success(repo) do
    update_sync(repo, %{last_synced_at: DateTime.utc_now(), last_sync_error: nil})
  end

  # Deliberately keeps `last_synced_at`: it says when this copy was last known
  # current, which is exactly the question a stale checkout raises. Overwriting
  # it with the time of the failure would erase the only useful number.
  defp record_failure(repo, message) do
    update_sync(repo, %{last_sync_error: message})
  end

  defp update_sync(repo, attrs) do
    repo
    |> ProjectRepo.sync_changeset(attrs)
    |> Repo.update()
    |> case do
      {:ok, repo} -> {:ok, repo}
      # The disk is already in whatever state it reached; losing the note about
      # it must not also lose the checkout.
      {:error, _changeset} -> {:ok, struct(repo, attrs)}
    end
  end

  ## Plumbing

  defp ensure_root do
    case root() do
      nil ->
        {:error, :not_configured}

      root ->
        case File.mkdir_p(root) do
          :ok -> {:ok, root}
          {:error, reason} -> {:error, {:root_unavailable, reason}}
        end
    end
  end

  defp validate_segment(value) when is_binary(value) do
    if Regex.match?(@segment, value), do: {:ok, value}, else: {:error, {:invalid_name, value}}
  end

  defp validate_segment(value), do: {:error, {:invalid_name, inspect(value)}}

  # Two passes on purpose. The first is this module's own, conservative enough
  # that nothing reaching git can be read as a flag or climb a directory; the
  # second is git's, which knows the rules about `.lock`, `@{` and the rest.
  # `refs/heads/` rather than `--branch`, because `--branch` also expands
  # shorthand like `@{-1}` and this is validation, not resolution.
  defp validate_branch(branch) when is_binary(branch) do
    with true <- byte_size(branch) <= @max_branch_bytes,
         true <- Regex.match?(@branch, branch),
         false <- String.contains?(branch, ".."),
         false <- String.contains?(branch, "//"),
         false <- String.ends_with?(branch, "/"),
         {:ok, _output} <-
           Git.run(["check-ref-format", "refs/heads/#{branch}"], local_opts()) do
      {:ok, branch}
    else
      _refused -> {:error, {:invalid_branch, branch}}
    end
  end

  defp validate_branch(branch), do: {:error, {:invalid_branch, inspect(branch)}}

  # The username is not secret and the token must never be written to
  # `.git/config`, so only the username goes in the URL. See
  # `RintoPMO.Workspace.Git`.
  defp remote_url(%ProjectRepo{credential: %{username: username}, git_url: git_url}) do
    case URI.parse(git_url) do
      %URI{scheme: "https"} = uri ->
        URI.to_string(%{uri | userinfo: URI.encode_www_form(username)})

      _other ->
        git_url
    end
  end

  defp remote_url(%ProjectRepo{git_url: git_url}), do: git_url

  defp git_opts(%{repo: repo, askpass: askpass, root: root}, timeout) do
    [timeout: timeout, askpass: askpass, credential: credential(repo), ceiling: root]
  end

  defp local_opts(%{root: root}), do: [timeout: setting(:local_timeout), ceiling: root]

  # For the one command that touches no repository at all.
  defp local_opts, do: [timeout: setting(:local_timeout)]

  defp credential(%ProjectRepo{credential: %{username: username, token: token}}),
    do: %{username: username, token: token}

  defp credential(_repo), do: nil

  defp setting(key) do
    :rinto_pmo
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(key, default(key))
  end

  defp default(:root), do: nil
  defp default(:ttl_ms), do: :timer.minutes(5)
  defp default(:fetch_timeout), do: :timer.seconds(5)
  defp default(:clone_timeout), do: :timer.minutes(2)
  defp default(:local_timeout), do: :timer.seconds(15)
  defp default(:worktree_retention_ms), do: :timer.hours(72)
end
