defmodule RintoPMO.WorkspaceTest do
  # Not async: the workspace root is application configuration, and the server
  # this exercises is the one the supervision tree started.
  use RintoPMO.DataCase, async: false
  use Oban.Testing, repo: RintoPMO.Repo

  alias RintoPMO.Projects.ProjectRepo
  alias RintoPMO.Workspace
  alias RintoPMO.Workspace.SyncWorker

  @moduletag :tmp_dir

  # A real repository on disk, cloned over a plain path. Nothing here reaches
  # the network: the parts that would -- credentials, the remote URL -- are
  # checked through what git records rather than by dialling anything.
  defp origin!(dir, default) do
    File.mkdir_p!(dir)
    git!(dir, ["init", "--quiet", "--initial-branch=#{default}"])
    git!(dir, ["config", "user.email", "test@example.com"])
    git!(dir, ["config", "user.name", "Test"])
    commit!(dir, "README.md", "one\n", "one")

    git!(dir, ["checkout", "--quiet", "-b", "feat/x"])
    commit!(dir, "topic.md", "topic\n", "topic")
    git!(dir, ["checkout", "--quiet", default])

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
    {default, attrs} = Keyword.pop(attrs, :default_branch, "main")
    root = Path.join(tmp_dir, "workspace")
    origin = origin!(Path.join(tmp_dir, "origin"), default)
    configure(root: root)

    project = insert(:project, slug: "acme")

    repo =
      insert(
        :project_repo,
        Keyword.merge([project: project, name: "backend", git_url: origin], attrs)
      )

    %{origin: origin, project: project, repo: repo, root: root}
  end

  defp reload(repo), do: Repo.get!(ProjectRepo, repo.id)

  defp mirror(root, project, repo), do: Path.join([root, project.slug, repo.id, ".mirror"])

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

      assert checkout.path == Path.join([root, "acme", repo.id, "worktrees", "main"])
      assert File.dir?(Path.join([root, "acme", repo.id, ".mirror"]))
    end

    test "survives the repository being renamed", %{tmp_dir: tmp_dir} do
      %{project: project, repo: repo} = fixture(tmp_dir)
      assert {:ok, first} = Workspace.perform_checkout(project, repo)
      %ProjectRepo{last_synced_at: cloned_at} = reload(repo)

      {:ok, renamed} =
        repo |> reload() |> ProjectRepo.changeset(%{name: "server"}) |> Repo.update()

      assert {:ok, again} = Workspace.perform_checkout(project, renamed)

      # Same directory, and nothing was cloned a second time: the name was never
      # what the working copy was filed under.
      assert again.path == first.path
      assert %ProjectRepo{last_synced_at: ^cloned_at} = reload(repo)
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

  describe "a checkout that names no branch" do
    test "takes whatever the remote calls its default", %{tmp_dir: tmp_dir} do
      %{origin: origin, project: project, repo: repo} =
        fixture(tmp_dir, default_branch: "develop")

      assert {:ok, checkout} = Workspace.perform_checkout(project, repo)

      # Not "main". Nothing anywhere ever guessed at one.
      assert checkout.branch == "develop"
      assert checkout.commit == head!(origin, "develop")
      assert Path.basename(checkout.path) == "develop"
    end

    # The reason it is read every time rather than recorded once: "no branch
    # named" means whatever the remote considers current, not whatever it
    # considered current the day somebody registered the URL.
    test "follows the remote when the default moves", %{tmp_dir: tmp_dir} do
      %{origin: origin, project: project, repo: repo} =
        fixture(tmp_dir, default_branch: "develop")

      assert {:ok, first} = Workspace.perform_checkout(project, repo)
      assert first.branch == "develop"

      git!(origin, ["symbolic-ref", "HEAD", "refs/heads/feat/x"])

      assert {:ok, second} = Workspace.perform_checkout(project, repo, force: true)
      assert second.branch == "feat/x"
    end

    test "a branch asked for wins and changes nothing about the repository",
         %{tmp_dir: tmp_dir} do
      %{project: project, repo: repo} = fixture(tmp_dir, default_branch: "develop")

      assert {:ok, checkout} = Workspace.perform_checkout(project, repo, branch: "feat/x")

      assert checkout.branch == "feat/x"
      # Nothing to record. The next checkout asks the remote again.
      assert {:ok, %{branch: "develop"}} = Workspace.perform_checkout(project, repo)
    end

    test "a remote naming no default is reported rather than guessed at", %{tmp_dir: tmp_dir} do
      %{project: project, repo: repo, root: root} =
        fixture(tmp_dir, default_branch: "develop")

      # A first checkout builds the mirror; detaching its HEAD afterwards is
      # the state a remote with no default branch would have produced, which a
      # clone over a local path is too helpful to reproduce on its own.
      assert {:ok, _checkout} = Workspace.perform_checkout(project, repo)
      mirror = mirror(root, project, repo)
      git!(mirror, ["update-ref", "--no-deref", "HEAD", head!(mirror, "refs/heads/develop")])

      # Reloaded, so the TTL keeps a fetch from putting HEAD back: what is
      # being tested is the mirror with no default branch, not git's fetch.
      assert {:error, :no_default_branch} = Workspace.perform_checkout(project, reload(repo))

      # Naming one is what fixes it, and only the caller can.
      assert {:ok, %{branch: "feat/x"}} =
               Workspace.perform_checkout(project, reload(repo), branch: "feat/x")
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

      refute File.exists?(Path.join([Workspace.root(), "acme", repo.id, ".mirror"]))
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

      config = File.read!(Path.join([Workspace.root(), "acme", repo.id, ".mirror", "config"]))
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

  describe "request_sync/1" do
    test "queues the work and answers with the job", %{tmp_dir: tmp_dir} do
      %{repo: repo} = fixture(tmp_dir)

      assert {:ok, %Oban.Job{}} = Workspace.request_sync(repo)
      assert_enqueued(worker: SyncWorker, args: %{project_repo_id: repo.id})
    end

    test "answers the same when one is already queued", %{tmp_dir: tmp_dir} do
      %{repo: repo} = fixture(tmp_dir)

      assert {:ok, %Oban.Job{id: id}} = Workspace.request_sync(repo)
      assert {:ok, %Oban.Job{id: ^id}} = Workspace.request_sync(repo)
    end

    test "queues nothing on a server that keeps no working copies", %{tmp_dir: tmp_dir} do
      %{repo: repo} = fixture(tmp_dir)
      configure(root: nil)

      assert {:error, :not_configured} = Workspace.request_sync(repo)
      refute_enqueued(worker: SyncWorker)
    end
  end

  describe "sync/1" do
    test "clones the mirror, and only the mirror", %{tmp_dir: tmp_dir} do
      %{project: project, repo: repo, root: root} = fixture(tmp_dir)

      assert :ok = Workspace.sync(repo.id)

      assert %ProjectRepo{last_synced_at: %DateTime{}, last_sync_error: nil} = reload(repo)

      # Every ref is available, which is what makes a repository usable...
      mirror = mirror(root, project, repo)
      assert head!(mirror, "refs/heads/main")
      assert head!(mirror, "refs/heads/feat/x")

      # ...and no branch was chosen, because nobody has asked about one yet.
      refute File.exists?(Path.join([root, "acme", repo.id, "worktrees"]))
    end

    test "makes the next checkout a local operation", %{tmp_dir: tmp_dir} do
      %{project: project, repo: repo} = fixture(tmp_dir)

      assert :ok = Workspace.sync(repo.id)

      assert {:ok, checkout} = Workspace.perform_checkout(project, reload(repo))
      assert File.read!(Path.join(checkout.path, "README.md")) == "one\n"
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
      assert File.dir?(Path.join([Workspace.root(), "acme", repo.id, "worktrees"]))
    end

    test "reaches a repository that was deleted, whose own checkout will never come", %{
      tmp_dir: tmp_dir
    } do
      %{project: project, repo: gone} = fixture(tmp_dir)
      assert {:ok, orphan} = Workspace.perform_checkout(project, gone, branch: "feat/x")
      age!(orphan.path, 4)

      # The row goes; the disk is deliberately left alone by the delete itself.
      Repo.delete!(gone)
      other = insert(:project_repo, project: project, git_url: Path.join(tmp_dir, "origin"))

      assert {:ok, _checkout} = Workspace.perform_checkout(project, other)

      refute File.exists?(orphan.path)
      # The mirror stays: it is the expensive thing, and nothing here decides a
      # clone is not coming back.
      assert File.dir?(Path.join([Workspace.root(), "acme", gone.id, ".mirror"]))
    end

    test "leaves git's own bookkeeping inside a mirror alone", %{tmp_dir: tmp_dir} do
      %{project: project, repo: repo} = fixture(tmp_dir)
      assert {:ok, topic} = Workspace.perform_checkout(project, repo, branch: "feat/x")
      admin = Path.join([Workspace.root(), "acme", repo.id, ".mirror", "worktrees"])
      assert File.dir?(admin)
      age!(topic.path, 4)

      assert {:ok, _main} = Workspace.perform_checkout(project, reload(repo))

      # A blind walk would have found `.mirror/worktrees` and collected the empty
      # directories out of git's own bookkeeping. The repository still answers.
      mirror = Path.join([Workspace.root(), "acme", repo.id, ".mirror"])
      assert mirror |> git!(["rev-parse", "--verify", "refs/heads/main"]) |> String.trim() != ""
      assert File.exists?(Path.join(mirror, "HEAD"))
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
