defmodule RintoPMO.WorkspaceTest do
  # Not async: the workspace root is application configuration, and the server
  # this exercises is the one the supervision tree started.
  use RintoPMO.DataCase, async: false

  alias RintoPMO.Projects.ProjectRepo
  alias RintoPMO.Workspace

  @moduletag :tmp_dir

  # A real repository on disk, cloned over a plain path. Nothing here reaches
  # the network: the parts that would -- credentials, the remote URL -- are
  # checked through what git records rather than by dialling anything.
  defp origin!(dir) do
    File.mkdir_p!(dir)
    git!(dir, ["init", "--quiet", "--initial-branch=main"])
    git!(dir, ["config", "user.email", "test@example.com"])
    git!(dir, ["config", "user.name", "Test"])
    commit!(dir, "README.md", "one\n", "one")

    git!(dir, ["checkout", "--quiet", "-b", "feat/x"])
    commit!(dir, "topic.md", "topic\n", "topic")
    git!(dir, ["checkout", "--quiet", "main"])

    dir
  end

  defp commit!(dir, file, contents, message) do
    File.write!(Path.join(dir, file), contents)
    git!(dir, ["add", "."])
    git!(dir, ["commit", "--quiet", "-m", message])
  end

  defp git!(dir, args) do
    case System.cmd("git", ["-C", dir | args], stderr_to_stdout: true) do
      {output, 0} -> output
      {output, status} -> flunk("git #{Enum.join(args, " ")} exited #{status}:\n#{output}")
    end
  end

  defp head!(dir, ref), do: dir |> git!(["rev-parse", ref]) |> String.trim()

  defp configure(overrides) do
    previous = Application.get_env(:rinto_pmo, Workspace, [])
    Application.put_env(:rinto_pmo, Workspace, Keyword.merge(previous, overrides))
    on_exit(fn -> Application.put_env(:rinto_pmo, Workspace, previous) end)
  end

  defp fixture(tmp_dir, attrs \\ []) do
    origin = origin!(Path.join(tmp_dir, "origin"))
    configure(root: Path.join(tmp_dir, "workspace"))

    project = insert(:project, slug: "acme")

    repo =
      insert(
        :project_repo,
        Keyword.merge([project: project, name: "backend", git_url: origin, branch: "main"], attrs)
      )

    %{origin: origin, project: project, repo: repo}
  end

  defp reload(repo), do: Repo.get!(ProjectRepo, repo.id)

  describe "configuration" do
    test "is off with no root", %{tmp_dir: tmp_dir} do
      %{project: project, repo: repo} = fixture(tmp_dir)
      configure(root: nil)

      refute Workspace.configured?()
      assert {:error, :not_configured} = Workspace.perform_checkout(project, repo)
    end

    test "treats a blank root as absent", %{tmp_dir: tmp_dir} do
      fixture(tmp_dir)
      configure(root: "   ")

      refute Workspace.configured?()
    end
  end

  describe "first checkout" do
    test "clones and hands back the branch on disk", %{tmp_dir: tmp_dir} do
      %{origin: origin, project: project, repo: repo} = fixture(tmp_dir)

      assert {:ok, checkout} = Workspace.perform_checkout(project, repo)

      assert checkout.branch == "main"
      assert checkout.commit == head!(origin, "main")
      assert checkout.sync_error == nil
      assert %DateTime{} = checkout.synced_at
      assert File.read!(Path.join(checkout.path, "README.md")) == "one\n"
    end

    test "puts the mirror and the worktree where the layout says", %{tmp_dir: tmp_dir} do
      %{project: project, repo: repo} = fixture(tmp_dir)
      root = Workspace.root()

      assert {:ok, checkout} = Workspace.perform_checkout(project, repo)

      assert checkout.path == Path.join([root, "acme", "backend", "worktrees", "main"])
      assert File.dir?(Path.join([root, "acme", "backend", ".mirror"]))
    end

    test "records when it happened", %{tmp_dir: tmp_dir} do
      %{project: project, repo: repo} = fixture(tmp_dir)

      assert {:ok, _checkout} = Workspace.perform_checkout(project, repo)

      assert %ProjectRepo{last_synced_at: %DateTime{}, last_sync_error: nil} = reload(repo)
    end

    test "refuses to push from what it clones", %{tmp_dir: tmp_dir} do
      %{project: project, repo: repo} = fixture(tmp_dir)

      assert {:ok, checkout} = Workspace.perform_checkout(project, repo)

      assert checkout.path
             |> git!(["config", "--get", "remote.origin.pushurl"])
             |> String.trim() == "rinto://refuses-to-push"
    end
  end

  describe "branches" do
    test "each gets its own worktree", %{tmp_dir: tmp_dir} do
      %{origin: origin, project: project, repo: repo} = fixture(tmp_dir)

      assert {:ok, main} = Workspace.perform_checkout(project, repo)
      assert {:ok, topic} = Workspace.perform_checkout(project, repo, branch: "feat/x")

      assert topic.commit == head!(origin, "feat/x")
      refute topic.path == main.path
      # The point of the layout: reading one is unaffected by the other.
      assert File.exists?(Path.join(topic.path, "topic.md"))
      refute File.exists?(Path.join(main.path, "topic.md"))
    end

    test "a name with a slash nests rather than collides", %{tmp_dir: tmp_dir} do
      %{project: project, repo: repo} = fixture(tmp_dir)

      assert {:ok, topic} = Workspace.perform_checkout(project, repo, branch: "feat/x")

      assert Path.basename(topic.path) == "x"
      assert topic.path |> Path.dirname() |> Path.basename() == "feat"
    end

    test "one that does not exist is named, not guessed at", %{tmp_dir: tmp_dir} do
      %{project: project, repo: repo} = fixture(tmp_dir)

      assert {:error, {:unknown_branch, "nope"}} =
               Workspace.perform_checkout(project, repo, branch: "nope")
    end

    test "one that could escape or be read as a flag is refused", %{tmp_dir: tmp_dir} do
      %{project: project, repo: repo} = fixture(tmp_dir)

      for branch <- ["../etc", "a/../../b", "--upload-pack=touch", "/abs", "a//b", "main/"] do
        assert {:error, {:invalid_branch, ^branch}} =
                 Workspace.perform_checkout(project, repo, branch: branch),
               "#{branch} was not refused"
      end
    end

    test "one git itself rejects is refused too", %{tmp_dir: tmp_dir} do
      %{project: project, repo: repo} = fixture(tmp_dir)

      # Passes this module's own pattern; only `check-ref-format` knows better.
      assert {:error, {:invalid_branch, "main.lock"}} =
               Workspace.perform_checkout(project, repo, branch: "main.lock")
    end
  end

  describe "freshness" do
    test "does not fetch again inside the TTL", %{tmp_dir: tmp_dir} do
      %{origin: origin, project: project, repo: repo} = fixture(tmp_dir)
      assert {:ok, first} = Workspace.perform_checkout(project, repo)

      commit!(origin, "README.md", "two\n", "two")

      assert {:ok, second} = Workspace.perform_checkout(project, reload(repo))
      assert second.commit == first.commit
    end

    test "fetches when asked to regardless", %{tmp_dir: tmp_dir} do
      %{origin: origin, project: project, repo: repo} = fixture(tmp_dir)
      assert {:ok, first} = Workspace.perform_checkout(project, repo)

      commit!(origin, "README.md", "two\n", "two")

      assert {:ok, second} = Workspace.perform_checkout(project, reload(repo), force: true)
      refute second.commit == first.commit
      assert second.commit == head!(origin, "main")
      assert File.read!(Path.join(second.path, "README.md")) == "two\n"
    end

    test "fetches once the TTL has passed", %{tmp_dir: tmp_dir} do
      %{origin: origin, project: project, repo: repo} = fixture(tmp_dir)
      assert {:ok, _first} = Workspace.perform_checkout(project, repo)

      commit!(origin, "README.md", "two\n", "two")
      configure(ttl_ms: 0)

      assert {:ok, second} = Workspace.perform_checkout(project, reload(repo))
      assert second.commit == head!(origin, "main")
    end
  end

  describe "a fetch that fails" do
    setup %{tmp_dir: tmp_dir} do
      fixture(tmp_dir)
    end

    test "serves the previous snapshot and says so", %{
      origin: origin,
      project: project,
      repo: repo
    } do
      assert {:ok, first} = Workspace.perform_checkout(project, repo)
      File.rm_rf!(origin)

      assert {:ok, second} = Workspace.perform_checkout(project, reload(repo), force: true)

      assert second.commit == first.commit
      assert second.sync_error =~ "git fetch failed"
      assert File.read!(Path.join(second.path, "README.md")) == "one\n"
    end

    test "keeps the time the copy was last known current", %{
      origin: origin,
      project: project,
      repo: repo
    } do
      assert {:ok, _first} = Workspace.perform_checkout(project, repo)
      %ProjectRepo{last_synced_at: was} = reload(repo)
      File.rm_rf!(origin)

      assert {:ok, _second} = Workspace.perform_checkout(project, reload(repo), force: true)

      assert %ProjectRepo{last_synced_at: ^was, last_sync_error: message} = reload(repo)
      assert message =~ "git fetch failed"
    end
  end

  describe "a first clone that fails" do
    test "is the caller's failure, and is recorded", %{tmp_dir: tmp_dir} do
      %{project: project, repo: repo} =
        fixture(tmp_dir, git_url: Path.join(tmp_dir, "nowhere"))

      assert {:error, {:git, _reason}} = Workspace.perform_checkout(project, repo)

      assert %ProjectRepo{last_synced_at: nil, last_sync_error: message} = reload(repo)
      assert message =~ "git clone failed"
    end

    test "leaves nothing half-cloned behind", %{tmp_dir: tmp_dir} do
      %{project: project, repo: repo} =
        fixture(tmp_dir, git_url: Path.join(tmp_dir, "nowhere"))

      assert {:error, _reason} = Workspace.perform_checkout(project, repo)

      refute File.exists?(Path.join([Workspace.root(), "acme", "backend", ".mirror"]))
    end
  end

  describe "credentials" do
    test "reach git without being written to disk", %{tmp_dir: tmp_dir} do
      %{project: project, repo: repo} = fixture(tmp_dir)
      assert {:ok, _first} = Workspace.perform_checkout(project, repo)

      # Point the mirror at an HTTPS remote it cannot reach. The fetch fails,
      # but `remote set-url` runs first, so what git recorded is exactly what
      # this system hands it.
      credential = insert(:repo_credential, username: "git-bot", token: "s3cr3t-token")

      {:ok, repo} =
        repo
        |> reload()
        |> Ecto.Changeset.change(%{
          git_url: "https://127.0.0.1:1/owner/repo.git",
          credential_id: credential.id
        })
        |> Repo.update()

      assert {:ok, checkout} = Workspace.perform_checkout(project, repo, force: true)

      recorded = checkout.path |> git!(["config", "--get", "remote.origin.url"]) |> String.trim()
      assert recorded == "https://git-bot@127.0.0.1:1/owner/repo.git"
      refute recorded =~ "s3cr3t-token"

      config = File.read!(Path.join([Workspace.root(), "acme", "backend", ".mirror", "config"]))
      refute config =~ "s3cr3t-token"
    end

    test "never appear in what a failure records", %{tmp_dir: tmp_dir} do
      credential = insert(:repo_credential, username: "git-bot", token: "s3cr3t-token")

      %{project: project, repo: repo} =
        fixture(tmp_dir,
          git_url: "https://127.0.0.1:1/owner/repo.git",
          credential_id: credential.id
        )

      assert {:error, _reason} = Workspace.perform_checkout(project, repo)

      assert %ProjectRepo{last_sync_error: message} = reload(repo)
      refute message =~ "s3cr3t-token"
    end
  end

  describe "a worktree that is not one" do
    test "is thrown away and rebuilt", %{tmp_dir: tmp_dir} do
      %{project: project, repo: repo} = fixture(tmp_dir)
      assert {:ok, first} = Workspace.perform_checkout(project, repo)

      # Whatever this is, it is not something `reset --hard` can drive.
      File.rm_rf!(Path.join(first.path, ".git"))
      File.write!(Path.join(first.path, "README.md"), "clobbered\n")

      assert {:ok, second} = Workspace.perform_checkout(project, reload(repo))

      assert second.path == first.path
      assert File.read!(Path.join(second.path, "README.md")) == "one\n"
    end
  end

  describe "sync/1" do
    test "brings a repository's own branch up to date", %{tmp_dir: tmp_dir} do
      %{origin: origin, repo: repo} = fixture(tmp_dir)

      assert :ok = Workspace.sync(repo.id)

      assert %ProjectRepo{last_synced_at: %DateTime{}, last_sync_error: nil} = reload(repo)

      assert File.read!(
               Path.join([Workspace.root(), "acme", "backend", "worktrees", "main", "README.md"])
             ) == "one\n"

      assert head!(origin, "main")
    end

    test "is not a failure when the repository is already gone", %{tmp_dir: tmp_dir} do
      %{repo: repo} = fixture(tmp_dir)
      Repo.delete!(repo)

      assert :ok = Workspace.sync(repo.id)
    end

    test "reports a repository that could never be cloned", %{tmp_dir: tmp_dir} do
      %{repo: repo} = fixture(tmp_dir, git_url: Path.join(tmp_dir, "nowhere"))

      assert {:error, {:git, _reason}} = Workspace.sync(repo.id)
    end
  end

  describe "sweeping worktrees" do
    # Recorded, not inferred: `reset --hard` on a worktree already at the right
    # commit leaves the directory untouched, so a test that waited for real time
    # to pass would still be testing the wrong thing.
    defp age!(path, days) do
      File.touch!(path, System.os_time(:second) - days * 24 * 60 * 60)
    end

    test "removes a branch nobody has asked about in days", %{tmp_dir: tmp_dir} do
      %{project: project, repo: repo} = fixture(tmp_dir)
      assert {:ok, topic} = Workspace.perform_checkout(project, repo, branch: "feat/x")
      age!(topic.path, 4)

      assert {:ok, main} = Workspace.perform_checkout(project, reload(repo))

      refute File.exists?(topic.path)
      assert File.dir?(main.path)
    end

    test "keeps one that was asked about recently", %{tmp_dir: tmp_dir} do
      %{project: project, repo: repo} = fixture(tmp_dir)
      assert {:ok, topic} = Workspace.perform_checkout(project, repo, branch: "feat/x")
      age!(topic.path, 2)

      assert {:ok, _main} = Workspace.perform_checkout(project, reload(repo))

      assert File.dir?(topic.path)
    end

    test "never sweeps the one it was just asked for", %{tmp_dir: tmp_dir} do
      %{project: project, repo: repo} = fixture(tmp_dir)
      assert {:ok, first} = Workspace.perform_checkout(project, repo)
      age!(first.path, 30)

      assert {:ok, again} = Workspace.perform_checkout(project, reload(repo))

      assert again.path == first.path
      assert File.dir?(again.path)
    end

    test "a checkout is what marks a branch as still wanted", %{tmp_dir: tmp_dir} do
      %{project: project, repo: repo} = fixture(tmp_dir)
      assert {:ok, topic} = Workspace.perform_checkout(project, repo, branch: "feat/x")
      age!(topic.path, 30)

      # Asked for again, so the next sweep must not take it.
      assert {:ok, _topic} = Workspace.perform_checkout(project, reload(repo), branch: "feat/x")
      assert {:ok, _main} = Workspace.perform_checkout(project, reload(repo))

      assert File.dir?(topic.path)
    end

    test "takes the directories a nested branch name left behind", %{tmp_dir: tmp_dir} do
      %{project: project, repo: repo} = fixture(tmp_dir)
      assert {:ok, topic} = Workspace.perform_checkout(project, repo, branch: "feat/x")
      age!(topic.path, 4)

      assert {:ok, _main} = Workspace.perform_checkout(project, reload(repo))

      refute File.exists?(Path.dirname(topic.path))
      assert File.dir?(Path.join([Workspace.root(), "acme", "backend", "worktrees"]))
    end

    test "leaves the mirror able to hand out that branch again", %{tmp_dir: tmp_dir} do
      %{origin: origin, project: project, repo: repo} = fixture(tmp_dir)
      assert {:ok, topic} = Workspace.perform_checkout(project, repo, branch: "feat/x")
      age!(topic.path, 4)
      assert {:ok, _main} = Workspace.perform_checkout(project, reload(repo))

      assert {:ok, again} = Workspace.perform_checkout(project, reload(repo), branch: "feat/x")

      assert again.path == topic.path
      assert again.commit == head!(origin, "feat/x")
      assert File.exists?(Path.join(again.path, "topic.md"))
    end
  end

  describe "the queue" do
    test "runs a checkout in the server process", %{tmp_dir: tmp_dir} do
      %{origin: origin, project: project, repo: repo} = fixture(tmp_dir)

      assert {:ok, checkout} = Workspace.checkout(project, repo, [])

      assert checkout.commit == head!(origin, "main")
    end

    test "answers every caller when several ask at once", %{tmp_dir: tmp_dir} do
      %{project: project, repo: repo} = fixture(tmp_dir)

      results =
        ["main", "feat/x", "main", "feat/x"]
        |> Task.async_stream(&Workspace.checkout(project, repo, branch: &1), max_concurrency: 4)
        |> Enum.map(fn {:ok, result} -> result end)

      assert Enum.all?(results, &match?({:ok, _checkout}, &1))
    end
  end
end
