defmodule RintoPMO.Agent.DocumentReviewerTest do
  # The stand-in pi executable is selected through process-wide application
  # configuration, so this cannot run beside another test changing it.
  use ExUnit.Case, async: false

  alias RintoPMO.Agent.DocumentReviewer

  @moduletag :tmp_dir

  test "adds the review actor's prompt without replacing the output contract", %{tmp_dir: tmp_dir} do
    argv = fake_pi(tmp_dir, "[]")

    assert {:ok, []} =
             DocumentReviewer.review(%{documents: []},
               system_prompt: "Prioritise operational safety and rollback risks."
             )

    recorded = argv.()
    assert recorded =~ "Prioritise operational safety and rollback risks."
    assert recorded =~ ~s("document_id": "<a document id you were given>")
    assert recorded =~ "Reply with the JSON array alone."
  end

  defp fake_pi(tmp_dir, answer) do
    argv_path = Path.join(tmp_dir, "argv")
    executable = Path.join(tmp_dir, "fake-pi")

    frame = %{
      "type" => "turn_end",
      "message" => %{"content" => [%{"type" => "text", "text" => answer}]}
    }

    File.write!(executable, """
    #!/bin/sh
    for argument; do printf '%s\n' "$argument" >> "#{argv_path}"; done
    printf '%s\n' '#{JSON.encode!(frame)}'
    """)

    File.chmod!(executable, 0o755)
    set_executable(executable)

    fn -> File.read!(argv_path) end
  end

  defp set_executable(executable) do
    previous = Application.get_env(:rinto_pmo, :pi_executable)
    Application.put_env(:rinto_pmo, :pi_executable, executable)
    on_exit(fn -> Application.put_env(:rinto_pmo, :pi_executable, previous) end)
  end
end
