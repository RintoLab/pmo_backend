defmodule RintoPMO.Agent.WbsGeneratorTest do
  # Not async: the stand-in pi is chosen through an application setting, which
  # is process-wide, and there is no per-call way to hand one in -- the point of
  # this module is that it builds pi's whole argv itself.
  use ExUnit.Case, async: false

  alias RintoPMO.Agent.WbsGenerator

  @moduletag :tmp_dir
  @moduletag :capture_log

  @input %{
    title: "上线方案",
    blocks: ["## 灰度\n\n先接十分之一。", "## 回滚\n\n一个开关。"]
  }

  describe "generate/2" do
    test "returns what pi printed, trimmed", %{tmp_dir: tmp_dir} do
      fake_pi(tmp_dir, stdout: "## 灰度\n- 接流量\n")

      assert WbsGenerator.generate(@input) == {:ok, "## 灰度\n- 接流量"}
    end

    test "sends the document as JSON and nothing else", %{tmp_dir: tmp_dir} do
      argv = fake_pi(tmp_dir, stdout: "- a task")

      assert {:ok, _breakdown} = WbsGenerator.generate(@input)

      assert {:ok, decoded} = argv.() |> List.last() |> JSON.decode()
      assert decoded == %{"title" => "上线方案", "blocks" => @input.blocks}
    end

    # Unlike naming, which is never given a document's contents at all.
    test "asks in print mode, without tools and without a session", %{tmp_dir: tmp_dir} do
      argv = fake_pi(tmp_dir, stdout: "- a task")

      assert {:ok, _breakdown} = WbsGenerator.generate(@input)

      recorded = argv.()
      assert "--print" in recorded
      assert "--no-tools" in recorded
      assert "--no-session" in recorded
    end

    test "hands each piece of output to :on_chunk as it arrives", %{tmp_dir: tmp_dir} do
      fake_pi(tmp_dir, stdout: "## 灰度\n- 接流量")

      test = self()

      assert {:ok, breakdown} =
               WbsGenerator.generate(@input, on_chunk: &send(test, {:chunk, &1}))

      # Whatever the chunking turns out to be, the pieces concatenate to the
      # answer -- which is the contract the client depends on.
      assert String.trim(collected()) == breakdown
    end

    test "does not require anybody to be watching", %{tmp_dir: tmp_dir} do
      fake_pi(tmp_dir, stdout: "- a task")

      assert {:ok, "- a task"} = WbsGenerator.generate(@input)
    end
  end

  # The one piece of provider output this module reads. Written so that reading
  # it wrong costs nothing: anything unrecognised is passed through verbatim.
  describe "what comes back when the provider refuses" do
    # The message alone. The status code is a fact about transport that the
    # person reading this cannot act on, and the log has the whole line.
    test "carries the provider's sentence and nothing around it", %{tmp_dir: tmp_dir} do
      body =
        ~s({"type":"GoUsageLimitError","message":"5-hour usage limit reached. Resets in 1hr 36min."})

      fake_pi(tmp_dir, stderr: "429: " <> body, exit: 1)

      assert {:error, {:pi_exit, 1, complaint}} = WbsGenerator.generate(@input)
      assert complaint == "5-hour usage limit reached. Resets in 1hr 36min."
    end

    test "passes anything it does not recognise through as it came", %{tmp_dir: tmp_dir} do
      fake_pi(tmp_dir, stderr: "command not found: some-model", exit: 1)

      assert {:error, {:pi_exit, 1, "command not found: some-model"}} =
               WbsGenerator.generate(@input)
    end

    test "keeps the body when the JSON carries no message", %{tmp_dir: tmp_dir} do
      fake_pi(tmp_dir, stderr: ~s(500: {"type":"ServerError"}), exit: 1)

      assert {:error, {:pi_exit, 1, complaint}} = WbsGenerator.generate(@input)
      assert complaint == ~s(500: {"type":"ServerError"})
    end

    test "says nothing was printed rather than inventing a reason", %{tmp_dir: tmp_dir} do
      fake_pi(tmp_dir, stdout: "   \n", exit: 0)

      assert WbsGenerator.generate(@input) == {:error, :empty_output}
    end
  end

  defp collected(acc \\ "") do
    receive do
      {:chunk, chunk} -> collected(acc <> chunk)
    after
      0 -> acc
    end
  end

  defp fake_pi(tmp_dir, opts) do
    argv_path = Path.join(tmp_dir, "argv")
    path = Path.join(tmp_dir, "fake-pi")

    File.write!(path, """
    #!/bin/sh
    for argument; do printf '%s\\n' "$argument" >> "#{argv_path}"; done
    #{if opts[:stdout], do: "printf '%s' '#{opts[:stdout]}'", else: ""}
    #{if opts[:stderr], do: "printf '%s' '#{opts[:stderr]}' >&2", else: ""}
    exit #{Keyword.get(opts, :exit, 0)}
    """)

    File.chmod!(path, 0o755)
    set_executable(path)

    fn -> argv_path |> File.read!() |> String.split("\n", trim: true) end
  end

  defp set_executable(executable) do
    previous = Application.get_env(:rinto_pmo, :pi_executable)
    Application.put_env(:rinto_pmo, :pi_executable, executable)
    on_exit(fn -> Application.put_env(:rinto_pmo, :pi_executable, previous) end)
  end
end
