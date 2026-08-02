defmodule RintoPMO.OSProcess.SpecTest do
  use ExUnit.Case, async: true

  alias RintoPMO.OSProcess.Spec

  defp opts(extra \\ []), do: Keyword.merge([id: "spec-test", cmd: "/bin/sh"], extra)

  describe "new/1 required options" do
    test "generates an id when none is given" do
      assert {:ok, %Spec{id: first}} = Spec.new(cmd: "/bin/sh")
      assert {:ok, %Spec{id: second}} = Spec.new(cmd: "/bin/sh")

      assert first != ""
      assert first != second
    end

    test "requires a command" do
      assert {:error, {:missing_option, :cmd}} = Spec.new(id: "x")
    end

    test "rejects a blank id" do
      assert {:error, {:invalid_option, :id, ""}} = Spec.new(id: "", cmd: "/bin/sh")
    end

    test "rejects a non-binary id" do
      assert {:error, {:invalid_option, :id, :atom}} = Spec.new(id: :atom, cmd: "/bin/sh")
    end
  end

  describe "new/1 executable resolution" do
    @describetag :tmp_dir

    test "keeps an existing absolute path" do
      assert {:ok, %Spec{argv: ["/bin/sh"]}} = Spec.new(opts())
    end

    test "resolves a bare name against PATH" do
      assert {:ok, %Spec{argv: [path]}} = Spec.new(opts(cmd: "sh"))
      assert String.ends_with?(path, "/sh")
    end

    test "reports a missing absolute path" do
      assert {:error, {:executable_not_found, "/nonexistent/xyz"}} =
               Spec.new(opts(cmd: "/nonexistent/xyz"))
    end

    test "reports a missing bare name" do
      name = "no-such-binary-#{System.unique_integer([:positive])}"
      assert {:error, {:executable_not_found, ^name}} = Spec.new(opts(cmd: name))
    end

    test "appends args after the resolved path" do
      assert {:ok, %Spec{argv: ["/bin/sh", "-c", "true"]}} = Spec.new(opts(args: ["-c", "true"]))
    end

    test "rejects non-binary args" do
      assert {:error, {:invalid_option, :args, _}} = Spec.new(opts(args: ["-c", true]))
    end

    test "rejects a regular file that is not executable", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "not-executable")
      File.write!(path, "#!/bin/sh\ntrue\n")
      File.chmod!(path, 0o644)

      assert {:error, {:executable_not_found, ^path}} = Spec.new(opts(cmd: path))
    end

    test "accepts the same file once it is executable", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "executable")
      File.write!(path, "#!/bin/sh\ntrue\n")
      File.chmod!(path, 0o755)

      assert {:ok, %Spec{argv: [^path]}} = Spec.new(opts(cmd: path))
    end

    test "rejects a directory", %{tmp_dir: tmp_dir} do
      assert {:error, {:executable_not_found, ^tmp_dir}} = Spec.new(opts(cmd: tmp_dir))
    end
  end

  describe "new/1 defaults" do
    test "owner defaults to the calling process" do
      me = self()
      assert {:ok, %Spec{owner: ^me}} = Spec.new(opts())
    end

    test "framing defaults to raw" do
      assert {:ok, %Spec{framing: :raw}} = Spec.new(opts())
    end

    test "kill_timeout comes from config" do
      configured = Application.get_env(:rinto_pmo, RintoPMO.OSProcess)[:kill_timeout]
      assert {:ok, %Spec{kill_timeout: ^configured}} = Spec.new(opts())
    end

    test "stdin, stdout, link and kill_group are always requested" do
      assert {:ok, %Spec{exec_opts: exec_opts}} = Spec.new(opts())

      for option <- [:stdin, :stdout, :link, :kill_group] do
        assert option in exec_opts
      end
    end

    test "never requests monitor, which erlexec would silently drop" do
      assert {:ok, %Spec{exec_opts: exec_opts}} = Spec.new(opts())
      refute :monitor in exec_opts
    end
  end

  describe "new/1 validation" do
    test "rejects an unknown framing" do
      assert {:error, {:invalid_option, :framing, :nope}} = Spec.new(opts(framing: :nope))
    end

    test "rejects an unknown stderr mode" do
      assert {:error, {:invalid_option, :stderr, :nope}} = Spec.new(opts(stderr: :nope))
    end

    test "rejects a missing working directory" do
      assert {:error, {:invalid_option, :cd, "/nonexistent/dir"}} =
               Spec.new(opts(cd: "/nonexistent/dir"))
    end

    test "rejects malformed env entries" do
      assert {:error, {:invalid_option, :env, _}} = Spec.new(opts(env: [{"K", :v}]))
      assert {:error, {:invalid_option, :env, _}} = Spec.new(opts(env: ["K=V"]))
    end

    test "accepts erlexec's unset and clear env entries" do
      assert {:ok, %Spec{exec_opts: exec_opts}} = Spec.new(opts(env: [{"K", false}, :clear]))
      assert {:env, [{"K", false}, :clear]} in exec_opts
    end

    test "rejects a non-positive kill_timeout" do
      assert {:error, {:invalid_option, :kill_timeout, 0}} = Spec.new(opts(kill_timeout: 0))
    end

    test "rejects an unusable max_line_bytes" do
      assert {:error, {:invalid_option, :max_line_bytes, 0}} = Spec.new(opts(max_line_bytes: 0))

      assert {:error, {:invalid_option, :max_line_bytes, :nope}} =
               Spec.new(opts(max_line_bytes: :nope))
    end

    test "max_line_bytes defaults to unbounded" do
      assert {:ok, %Spec{max_line_bytes: :infinity}} = Spec.new(opts())
      assert {:ok, %Spec{max_line_bytes: 64}} = Spec.new(opts(max_line_bytes: 64))
    end

    test "rejects an owner that is neither a pid nor a live registered name" do
      assert {:error, {:invalid_option, :owner, :nobody}} = Spec.new(opts(owner: :nobody))
      assert {:error, {:invalid_option, :owner, "nobody"}} = Spec.new(opts(owner: "nobody"))
    end

    test "resolves a registered owner name to its pid" do
      name = :"spec_test_owner_#{System.unique_integer([:positive])}"
      Process.register(self(), name)

      me = self()
      assert {:ok, %Spec{owner: ^me}} = Spec.new(opts(owner: name))
    end
  end

  describe "new/1 stderr routing" do
    test "owner mode delivers stderr as its own stream" do
      assert {:ok, %Spec{exec_opts: exec_opts}} = Spec.new(opts(stderr: :owner))
      assert :stderr in exec_opts
    end

    test "stdout mode merges the streams" do
      assert {:ok, %Spec{exec_opts: exec_opts}} = Spec.new(opts(stderr: :stdout))
      assert {:stderr, :stdout} in exec_opts
    end

    test "discard mode routes to the null device" do
      assert {:ok, %Spec{exec_opts: exec_opts}} = Spec.new(opts(stderr: :discard))
      assert {:stderr, :null} in exec_opts
    end
  end

  describe "shutdown_timeout/1" do
    test "leaves slack beyond the SIGTERM grace" do
      {:ok, spec} = Spec.new(opts(kill_timeout: 5))
      assert Spec.shutdown_timeout(spec) == 7_000
    end

    test "reap_timeout leaves terminate/2 room to report the exit event" do
      {:ok, spec} = Spec.new(opts(kill_timeout: 5))

      assert Spec.reap_timeout(spec) < Spec.shutdown_timeout(spec)
      assert Spec.reap_timeout(spec) > spec.kill_timeout * 1_000
    end
  end
end
