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
    test "returns the model's answer, trimmed", %{tmp_dir: tmp_dir} do
      fake_pi(tmp_dir, says: "## 灰度\n- 接流量\n")

      assert WbsGenerator.generate(@input) == {:ok, "## 灰度\n- 接流量"}
    end

    test "sends the document as JSON and nothing else", %{tmp_dir: tmp_dir} do
      argv = fake_pi(tmp_dir, says: "- a task")

      assert {:ok, _breakdown} = WbsGenerator.generate(@input)

      assert {:ok, decoded} = argv.() |> List.last() |> JSON.decode()
      assert decoded == %{"title" => "上线方案", "blocks" => @input.blocks}
    end

    # Unlike naming, which is never given a document's contents at all.
    test "asks in print mode, without tools and without a session", %{tmp_dir: tmp_dir} do
      argv = fake_pi(tmp_dir, says: "- a task")

      assert {:ok, _breakdown} = WbsGenerator.generate(@input)

      recorded = argv.()
      assert "--print" in recorded
      assert "--no-tools" in recorded
      assert "--no-session" in recorded
    end

    # The whole reason this reads events rather than pi's rendered output: text
    # mode says nothing until it is done, which leaves a person watching a
    # spinner and the idle clock measuring the call's duration instead of its
    # silence. See the moduledoc.
    test "asks for the event stream rather than rendered text", %{tmp_dir: tmp_dir} do
      argv = fake_pi(tmp_dir, says: "- a task")

      assert {:ok, _breakdown} = WbsGenerator.generate(@input)

      recorded = argv.()
      assert "json" in recorded
      refute "text" in recorded
    end

    test "hands each piece of output to :on_chunk as it arrives", %{tmp_dir: tmp_dir} do
      fake_pi(tmp_dir, says: "## 灰度\n- 接流量")

      test = self()

      assert {:ok, breakdown} =
               WbsGenerator.generate(@input, on_chunk: &send(test, {:chunk, &1}))

      # Whatever the chunking turns out to be, the pieces concatenate to the
      # answer -- which is the contract the client depends on.
      assert String.trim(collected()) == breakdown
    end

    # What the model worked out on the way is not the breakdown, and nobody
    # waiting for a task list asked to watch it be argued into existence.
    test "does not hand on what the model was thinking", %{tmp_dir: tmp_dir} do
      fake_pi(tmp_dir, thinks: "先看看有几件事", says: "- a task")

      test = self()

      assert {:ok, "- a task"} =
               WbsGenerator.generate(@input, on_chunk: &send(test, {:chunk, &1}))

      refute collected() =~ "先看看"
    end

    test "does not require anybody to be watching", %{tmp_dir: tmp_dir} do
      fake_pi(tmp_dir, says: "- a task")

      assert {:ok, "- a task"} = WbsGenerator.generate(@input)
    end

    # The events are pi's own and carry no compatibility promise, so the answer
    # is taken from the finished message and the deltas are only a fallback.
    # A pi that renames the delta event still produces a breakdown.
    test "answers from the finished message, not from the pieces", %{tmp_dir: tmp_dir} do
      fake_pi(tmp_dir, says: "- a task", stream: false)

      assert {:ok, "- a task"} = WbsGenerator.generate(@input)
    end

    # And the other way round: a provider that streams but whose turn carries
    # no finished text still answers, because the pieces were kept.
    test "falls back to the streamed pieces when the turn carries no text", %{tmp_dir: tmp_dir} do
      fake_pi(tmp_dir, says: "- a task", finished_text: false)

      assert {:ok, "- a task"} = WbsGenerator.generate(@input)
    end

    # An unreadable line is still the process being alive, which is most of
    # what reading it is for.
    test "ignores lines it cannot read", %{tmp_dir: tmp_dir} do
      fake_pi(tmp_dir, says: "- a task", noise: true)

      assert {:ok, "- a task"} = WbsGenerator.generate(@input)
    end
  end

  # The one piece of provider output this module reads. Written so that reading
  # it wrong costs nothing: anything unrecognised is passed through verbatim.
  describe "what comes back when the provider refuses" do
    # Under `--mode json` pi exits 0 and puts the refusal in the finished turn.
    # Missing this would report every refusal as an empty answer and throw away
    # the sentence saying why.
    test "reads a refusal out of a turn that exited zero", %{tmp_dir: tmp_dir} do
      body =
        ~s({"type":"GoUsageLimitError","message":"5-hour usage limit reached. Resets in 1hr 36min."})

      fake_pi(tmp_dir, refuses: "429: " <> body)

      assert {:error, {:provider_refused, complaint}} = WbsGenerator.generate(@input)
      assert complaint == "5-hour usage limit reached. Resets in 1hr 36min."
    end

    test "passes a refusal it does not recognise through as it came", %{tmp_dir: tmp_dir} do
      fake_pi(tmp_dir, refuses: "upstream said no")

      assert {:error, {:provider_refused, "upstream said no"}} = WbsGenerator.generate(@input)
    end

    test "says a refusal happened even when the reason is missing", %{tmp_dir: tmp_dir} do
      fake_pi(tmp_dir, refuses: :without_saying_why)

      assert {:error, {:provider_refused, complaint}} = WbsGenerator.generate(@input)
      assert complaint =~ "refused"
    end

    # pi's own failures still arrive the old way: non-zero, with the complaint
    # on stderr.
    test "carries pi's sentence and nothing around it", %{tmp_dir: tmp_dir} do
      body = ~s({"type":"ConfigError","message":"no credentials for provider go"})

      fake_pi(tmp_dir, stderr: "401: " <> body, exit: 1)

      assert {:error, {:pi_exit, 1, complaint}} = WbsGenerator.generate(@input)
      assert complaint == "no credentials for provider go"
    end

    test "keeps the body when the JSON carries no message", %{tmp_dir: tmp_dir} do
      fake_pi(tmp_dir, stderr: ~s(500: {"type":"ServerError"}), exit: 1)

      assert {:error, {:pi_exit, 1, complaint}} = WbsGenerator.generate(@input)
      assert complaint == ~s(500: {"type":"ServerError"})
    end

    test "says nothing was printed rather than inventing a reason", %{tmp_dir: tmp_dir} do
      fake_pi(tmp_dir, script: "true")

      assert WbsGenerator.generate(@input) == {:error, :empty_output}
    end
  end

  # The clock measures silence, not duration. There is no budget for the call
  # as a whole: what decides how long a breakdown takes is how much work the
  # document implies, which is the question being asked.
  describe "when the call goes quiet" do
    # Not smaller, and this is the trap: the first output of a healthy call
    # arrives about 400ms after the process is asked for, which is spawn cost
    # and not the model thinking. A window under that fires during startup and
    # the test passes for the wrong reason -- or, for the one below, fails for
    # the wrong reason.
    @idle 600

    test "gives up on a call that produces nothing", %{tmp_dir: tmp_dir} do
      fake_pi(tmp_dir, script: "sleep 5")

      assert WbsGenerator.generate(@input, idle_timeout: @idle) == {:error, :stalled}
    end

    # Wider than the two above, and it has to be. This is the one test that
    # fails if the window is crossed, so its margins are what protect it from
    # the machine rather than from the code: the suite runs this right after
    # dialyzer, and under that load both the ~400ms spawn and the gaps stretch.
    # It caught exactly that once, so the numbers are a floor and not a taste.
    @generous 1_500

    # The point of the whole arrangement: this call runs twice the window and
    # finishes anyway, because it never stops producing.
    test "waits as long as output keeps arriving", %{tmp_dir: tmp_dir} do
      fake_pi(tmp_dir,
        script: """
        i=0
        while [ $i -lt 30 ]; do
          i=$((i + 1))
          printf '{"assistantMessageEvent":{"type":"text_delta","delta":"- task %s\\\\n"}}\\n' "$i"
          sleep 0.1
        done
        """
      )

      assert {:ok, breakdown} = WbsGenerator.generate(@input, idle_timeout: @generous)

      assert breakdown =~ "- task 1"
      assert breakdown =~ "- task 30"
    end

    # Thinking counts as being alive even though nothing is handed on. Under
    # text mode this window was the whole silence before the first token, which
    # is exactly the wait that killed real documents.
    test "waits while the model is only thinking", %{tmp_dir: tmp_dir} do
      fake_pi(tmp_dir,
        script: """
        i=0
        while [ $i -lt 20 ]; do
          i=$((i + 1))
          printf '{"assistantMessageEvent":{"type":"thinking_delta","delta":"hmm"}}\\n'
          sleep 0.1
        done
        printf '{"assistantMessageEvent":{"type":"text_delta","delta":"- a task"}}\\n'
        """
      )

      assert {:ok, "- a task"} = WbsGenerator.generate(@input, idle_timeout: @generous)
    end

    test "drops what it had rather than filing half a breakdown", %{tmp_dir: tmp_dir} do
      fake_pi(tmp_dir,
        script: """
        printf '{"assistantMessageEvent":{"type":"text_delta","delta":"- half a task"}}\\n'
        sleep 5
        """
      )

      assert WbsGenerator.generate(@input, idle_timeout: @idle) == {:error, :stalled}
    end
  end

  defp collected(acc \\ "") do
    receive do
      {:chunk, chunk} -> collected(acc <> chunk)
    after
      0 -> acc
    end
  end

  # Stands in for `pi --print --mode json`: one JSON object per line, the
  # model's answer arriving as deltas and again whole in the finished turn.
  # Written as options rather than as a script so that a test says what pi did,
  # not how NDJSON is spelled.
  defp fake_pi(tmp_dir, opts) do
    argv_path = Path.join(tmp_dir, "argv")
    path = Path.join(tmp_dir, "fake-pi")

    File.write!(path, """
    #!/bin/sh
    for argument; do printf '%s\\n' "$argument" >> "#{argv_path}"; done
    #{opts[:script]}
    #{lines(opts)}
    #{if opts[:stderr], do: "printf '%s' '#{opts[:stderr]}' >&2", else: ""}
    exit #{Keyword.get(opts, :exit, 0)}
    """)

    File.chmod!(path, 0o755)
    set_executable(path)

    fn -> argv_path |> File.read!() |> String.split("\n", trim: true) end
  end

  defp lines(opts) do
    opts
    |> events()
    |> Enum.map_join("\n", &"printf '%s\\n' '#{JSON.encode!(&1)}'")
  end

  defp events(opts) do
    thinking = if opts[:thinks], do: [delta("thinking_delta", opts[:thinks])], else: []
    noise = if opts[:noise], do: ["not json at all"], else: []

    cond do
      complaint = opts[:refuses] ->
        [%{"type" => "turn_start"}] ++ thinking ++ [turn_end(refusal(complaint))]

      said = opts[:says] ->
        streamed = if opts[:stream] == false, do: [], else: [delta("text_delta", said)]
        finished = if opts[:finished_text] == false, do: %{}, else: %{"text" => said}

        [%{"type" => "turn_start"}] ++ thinking ++ noise ++ streamed ++ [turn_end(finished)]

      true ->
        []
    end
  end

  defp delta(type, text) do
    %{"type" => "message_update", "assistantMessageEvent" => %{"type" => type, "delta" => text}}
  end

  defp refusal(:without_saying_why), do: %{"stopReason" => "error"}

  defp refusal(complaint),
    do: %{"stopReason" => "error", "errorMessage" => complaint}

  defp turn_end(%{"text" => text}) do
    %{"type" => "turn_end", "message" => %{"content" => [%{"type" => "text", "text" => text}]}}
  end

  defp turn_end(%{"stopReason" => _reason} = refusal) do
    %{"type" => "turn_end", "message" => Map.put(refusal, "content", [])}
  end

  defp turn_end(_no_text) do
    %{"type" => "turn_end", "message" => %{"content" => []}}
  end

  defp set_executable(executable) do
    previous = Application.get_env(:rinto_pmo, :pi_executable)
    Application.put_env(:rinto_pmo, :pi_executable, executable)
    on_exit(fn -> Application.put_env(:rinto_pmo, :pi_executable, previous) end)
  end
end
