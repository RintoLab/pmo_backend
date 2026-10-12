defmodule RintoPMO.Agent.PrintProcessTest do
  # The fake executable is configured application-wide.
  use ExUnit.Case, async: false

  alias RintoPMO.Agent.Print
  alias RintoPMO.Agent.TaskEstimator

  @moduletag :tmp_dir
  @moduletag :capture_log

  test "delivers large estimation context and system prompts intact", %{tmp_dir: tmp_dir} do
    fake_pi(tmp_dir)

    input = %{
      tasks: [%{id: "task-1", title: "Implement", description: "Details"}],
      history: [],
      context: %{documents: [%{content: String.duplicate("需求说明\n", 12_000)}]}
    }

    standing = String.duplicate("估算规则\n", 6_000)
    assert byte_size(JSON.encode!(input)) > 65_535
    assert byte_size(standing) > 65_535

    assert {:ok, [%{"id" => "task-1", "likely" => 20}]} =
             TaskEstimator.estimate_time(input,
               system_prompt: standing,
               provider: "test-provider",
               model: "test-model",
               thinking: "off"
             )

    assert File.read!(Path.join(tmp_dir, "stdin")) == JSON.encode!(input)
    assert String.starts_with?(File.read!(Path.join(tmp_dir, "system")), String.trim(standing))

    argv = File.read!(Path.join(tmp_dir, "argv"))
    assert byte_size(argv) < 2_000
    assert argv =~ "--provider\ntest-provider\n--model\ntest-model\n--thinking\noff\n"
    assert_cleaned_up(tmp_dir)
  end

  test "keeps short messages literal when they resemble CLI options", %{tmp_dir: tmp_dir} do
    fake_pi(tmp_dir)
    message = "--help\n@not-a-file\n中文"

    assert {:ok, _answer} = Print.run("Reply with JSON.", message)
    assert File.read!(Path.join(tmp_dir, "stdin")) == message
    assert File.read!(Path.join(tmp_dir, "system")) == "Reply with JSON."
    assert_cleaned_up(tmp_dir)
  end

  test "removes prompt files after Pi fails", %{tmp_dir: tmp_dir} do
    fake_pi(tmp_dir, 1)

    assert {:error, {:pi_exit, 1, "provider unavailable"}} = Print.run("System", "User")
    assert_cleaned_up(tmp_dir)
  end

  defp fake_pi(tmp_dir, exit_code \\ 0) do
    path = Path.join(tmp_dir, "fake-pi")

    File.write!(path, """
    #!/bin/sh
    set -eu
    printf '%s\\n' "$@" > '#{tmp_dir}/argv'
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --system-prompt)
          shift
          printf '%s' "$1" > '#{tmp_dir}/prompt-path'
          cat "$1" > '#{tmp_dir}/system'
          ;;
      esac
      shift
    done
    cat > '#{tmp_dir}/stdin'
    if [ #{exit_code} -ne 0 ]; then
      printf '%s' 'provider unavailable' >&2
      exit #{exit_code}
    fi
    printf '%s\\n' '{"type":"turn_end","message":{"role":"assistant","content":[{"type":"text","text":"[{\\"id\\":\\"task-1\\",\\"likely\\":20}]"}]}}'
    """)

    File.chmod!(path, 0o755)
    previous = Application.fetch_env!(:rinto_pmo, :pi_executable)
    Application.put_env(:rinto_pmo, :pi_executable, path)
    on_exit(fn -> Application.put_env(:rinto_pmo, :pi_executable, previous) end)
  end

  defp assert_cleaned_up(tmp_dir) do
    prompt_path = File.read!(Path.join(tmp_dir, "prompt-path"))
    refute File.exists?(prompt_path)
    refute File.exists?(Path.dirname(prompt_path))
  end
end
