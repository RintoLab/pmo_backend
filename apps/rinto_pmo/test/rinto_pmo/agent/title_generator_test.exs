defmodule RintoPMO.Agent.TitleGeneratorTest do
  # Not async: the stand-in pi is chosen through an application setting, which
  # is process-wide, and there is no per-call way to hand one in -- the point of
  # this module is that it builds pi's whole argv itself.
  use ExUnit.Case, async: false

  alias RintoPMO.Agent.TitleGenerator

  @moduletag :tmp_dir
  @moduletag :capture_log

  @input %{
    first_user_message: "帮我看看这个文档的上线流程有没有遗漏",
    references: [%{type: "document", title: "项目上线方案"}],
    locale: "zh-CN"
  }

  describe "generate/2" do
    test "returns what pi printed, trimmed", %{tmp_dir: tmp_dir} do
      fake_pi(tmp_dir, stdout: "上线流程遗漏检查\n")

      assert TitleGenerator.generate(@input) == {:ok, "上线流程遗漏检查"}
    end

    test "asks in print mode, without tools and without a session", %{tmp_dir: tmp_dir} do
      argv = fake_pi(tmp_dir, stdout: "上线流程遗漏检查")

      assert {:ok, _title} = TitleGenerator.generate(@input)

      recorded = argv.()
      assert "--print" in recorded
      assert "--no-tools" in recorded
      assert "--no-session" in recorded
      # A title is not worth a document read, a bash call or a session file.
      assert "--mode" in recorded
    end

    test "sends the input as JSON and nothing else", %{tmp_dir: tmp_dir} do
      argv = fake_pi(tmp_dir, stdout: "上线流程遗漏检查")

      assert {:ok, _title} = TitleGenerator.generate(@input)

      assert {:ok, decoded} = argv.() |> List.last() |> JSON.decode()

      assert decoded == %{
               "first_user_message" => "帮我看看这个文档的上线流程有没有遗漏",
               "references" => [%{"type" => "document", "title" => "项目上线方案"}],
               "locale" => "zh-CN"
             }
    end

    test "passes the provider and model it was given", %{tmp_dir: tmp_dir} do
      argv = fake_pi(tmp_dir, stdout: "A title")

      assert {:ok, _title} =
               TitleGenerator.generate(@input, provider: "google", model: "gemini-flash")

      recorded = argv.()
      assert "google" in recorded
      assert "gemini-flash" in recorded
    end

    test "passes the naming role's thinking level", %{tmp_dir: tmp_dir} do
      argv = fake_pi(tmp_dir, stdout: "A title")

      assert {:ok, _title} =
               TitleGenerator.generate(@input,
                 provider: "google",
                 model: "gemini-flash",
                 thinking: "off"
               )

      assert ["--thinking", "off"] ==
               argv.() |> Enum.drop_while(&(&1 != "--thinking")) |> Enum.take(2)
    end

    test "asks pi to pick when there is nothing to inherit from", %{tmp_dir: tmp_dir} do
      argv = fake_pi(tmp_dir, stdout: "A title")

      assert {:ok, _title} = TitleGenerator.generate(@input)

      recorded = argv.()
      refute "--provider" in recorded
      refute "--model" in recorded
      refute "--thinking" in recorded
    end

    # The role steers what a title pays attention to; the built-in rules decide
    # what a title *is*. Second, so they have the last word: a standing
    # instruction that could drop "reply with the title alone" would hand a
    # paragraph to a caller about to write it into a column.
    test "puts the role's standing instruction in front of the built-in rules",
         %{tmp_dir: tmp_dir} do
      argv = fake_pi(tmp_dir, stdout: "A title")

      assert {:ok, _title} =
               TitleGenerator.generate(@input, system_prompt: "Lead with the subsystem.")

      # Recorded a line at a time, so the prompt arrives as its lines: the
      # instruction is the first of them and the built-in rules follow.
      assert ["Lead with the subsystem." | rules] =
               argv.() |> Enum.drop_while(&(&1 != "--system-prompt")) |> Enum.drop(1)

      assert Enum.any?(rules, &String.starts_with?(&1, "You name conversations."))
    end

    test "runs on the built-in rules alone when the role has no instruction",
         %{tmp_dir: tmp_dir} do
      argv = fake_pi(tmp_dir, stdout: "A title")

      assert {:ok, _title} = TitleGenerator.generate(@input, system_prompt: "   ")

      assert [first | _rest] =
               argv.() |> Enum.drop_while(&(&1 != "--system-prompt")) |> Enum.drop(1)

      assert String.starts_with?(first, "You name conversations.")
    end

    test "reports a provider that refused", %{tmp_dir: tmp_dir} do
      fake_pi(tmp_dir, stderr: "no credentials for provider", exit: 1)

      assert TitleGenerator.generate(@input) == {:error, {:pi_exit, 1}}
    end

    test "reports an answer with nothing in it", %{tmp_dir: tmp_dir} do
      fake_pi(tmp_dir, stdout: "   \n")

      assert TitleGenerator.generate(@input) == {:error, :empty_output}
    end

    test "reports a pi that is not installed" do
      set_executable("definitely-not-pi")

      assert TitleGenerator.generate(@input) == {:error, :pi_not_found}
    end

    test "gives up rather than holding a queue slot open", %{tmp_dir: tmp_dir} do
      fake_pi(tmp_dir, stdout: "too late", sleep: 5)

      assert TitleGenerator.generate(@input, timeout: 100) == {:error, :timeout}
    end

    test "leaves nothing behind in the session directory", %{tmp_dir: tmp_dir} do
      fake_pi(tmp_dir, stdout: "A title")

      before = ls_tmp()
      assert {:ok, _title} = TitleGenerator.generate(@input)

      assert ls_tmp() == before
    end
  end

  # Writes a stand-in `pi --print` and points the application at it. Returns a
  # function reading back the arguments it was called with, which is most of
  # what there is to check here: everything this module decides ends up in argv.
  defp fake_pi(tmp_dir, opts) do
    argv_path = Path.join(tmp_dir, "argv")
    path = Path.join(tmp_dir, "fake-pi")

    File.write!(path, """
    #!/bin/sh
    for argument; do printf '%s\\n' "$argument" >> "#{argv_path}"; done
    #{if opts[:sleep], do: "sleep #{opts[:sleep]}", else: ""}
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

  defp ls_tmp do
    System.tmp_dir!() |> File.ls!() |> Enum.filter(&String.starts_with?(&1, "rinto-pmo-pi-title"))
  end
end
