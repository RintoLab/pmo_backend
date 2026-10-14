defmodule RintoPMO.PromptShortcutsTest do
  use RintoPMO.DataCase, async: true

  alias RintoPMO.Documents.DocumentBlock
  alias RintoPMO.Documents.Markdown
  alias RintoPMO.PromptShortcuts
  alias RintoPMO.PromptShortcuts.Presets
  alias RintoPMO.PromptShortcuts.PromptShortcut
  alias RintoPMO.Tasks.Breakdown

  defp attrs(overrides \\ %{}) do
    Map.merge(
      %{"resource_type" => "document", "label" => "通读文档", "prompt" => "读一遍。"},
      overrides
    )
  end

  defp outcome_for(outcomes, label) do
    Enum.find(outcomes, fn
      {_tag, %PromptShortcut{label: ^label}} -> true
      _other -> false
    end)
  end

  test "requirement workflow presets seed once and preserve customized prompts on upgrade" do
    Presets.seed()

    workflow =
      PromptShortcuts.list_shortcuts()
      |> Enum.filter(&(&1.resource_type == "requirement"))

    assert Enum.sort(Enum.map(workflow, & &1.label)) ==
             Enum.sort(["明确需求", "澄清需求", "设计方案", "拆分任务", "一致性检查", "同步任务"])

    for shortcut <- workflow do
      assert shortcut.prompt =~ "rinto-spec-workflow"
      assert shortcut.prompt =~ "requirement show"
    end

    plan = Enum.find(workflow, &(&1.label == "设计方案"))
    {:ok, _customized} = PromptShortcuts.update_shortcut(plan, %{"prompt" => "保留我的设计约定"})
    assert {:default_only, preserved} = outcome_for(Presets.seed(), "设计方案")
    assert preserved.prompt == "保留我的设计约定"
    assert preserved.default_prompt == plan.default_prompt
    assert Enum.count(PromptShortcuts.list_shortcuts(), &(&1.resource_type == "requirement")) == 6
  end

  describe "create_shortcut/1" do
    test "generates a key and leaves no default to reset to" do
      assert {:ok, shortcut} = PromptShortcuts.create_shortcut(attrs())

      assert String.length(shortcut.key) == 16
      assert shortcut.default_prompt == nil
    end

    test "ignores a key and a default the caller tried to choose" do
      assert {:ok, shortcut} =
               PromptShortcuts.create_shortcut(
                 attrs(%{"key" => "chosen", "default_prompt" => "mine"})
               )

      refute shortcut.key == "chosen"
      assert shortcut.default_prompt == nil
    end

    test "two rows do not collide" do
      {:ok, one} = PromptShortcuts.create_shortcut(attrs())
      {:ok, two} = PromptShortcuts.create_shortcut(attrs())

      refute one.key == two.key
    end

    test "accepts no resource type, which means 'offer this with no references'" do
      assert {:ok, %PromptShortcut{resource_type: nil}} =
               PromptShortcuts.create_shortcut(attrs(%{"resource_type" => nil}))
    end

    test "refuses a resource type the reference scheme does not have" do
      assert {:error, changeset} =
               PromptShortcuts.create_shortcut(attrs(%{"resource_type" => "note"}))

      assert "is invalid" in errors_on(changeset).resource_type
    end

    test "refuses a shortcut with no prompt" do
      assert {:error, changeset} = PromptShortcuts.create_shortcut(attrs(%{"prompt" => nil}))

      assert "can't be blank" in errors_on(changeset).prompt
    end
  end

  describe "reset_shortcut/1" do
    test "refuses a shortcut nobody shipped" do
      {:ok, shortcut} = PromptShortcuts.create_shortcut(attrs())

      assert {:error, :not_a_preset, %{}} = PromptShortcuts.reset_shortcut(shortcut)
    end

    test "puts the prompt back and leaves a renamed label alone" do
      [{:created, preset} | _rest] = Presets.seed()

      {:ok, edited} =
        PromptShortcuts.update_shortcut(preset, %{"prompt" => "我自己写的", "label" => "我的名字"})

      assert {:ok, reset} = PromptShortcuts.reset_shortcut(edited)

      assert reset.prompt == preset.default_prompt
      assert reset.label == "我的名字"
    end
  end

  # One preset is offered against annotations. The judgement it exists to
  # carry is which notes may be acted on at all -- a note that names a
  # problem without naming a fix gets a question, not a guess proposed
  # against it.
  describe "the annotation preset" do
    test "proposes, and only for the notes it is sure about" do
      outcomes = Presets.seed()

      refute outcome_for(outcomes, "梳理批注")

      assert {:created, act} = outcome_for(outcomes, "按批注提案")
      assert act.resource_type == "annotation"
      assert act.prompt =~ "rinto-pmo doc propose"
      assert act.prompt == act.default_prompt
    end

    test "the proposing one keeps the notes it is unsure about out of the document" do
      # The whole judgement the preset exists to carry: a note that names a
      # problem without naming a fix gets a question, not a guess proposed
      # against it. Losing that half leaves it rewriting whatever it was
      # handed, and a wrong proposal costs more to unpick than a missing one.
      {:created, act} = outcome_for(Presets.seed(), "按批注提案")

      assert act.prompt =~ "存疑"
      assert act.prompt =~ "一条都不清楚就一条都不提"

      # Confirming a note is the person's act, and the preset has to say so:
      # nothing in the CLI would stop it, because there is no verb for it.
      assert act.prompt =~ "不要确认批注"

      # Read first, and read the working copy -- a proposal computed against
      # the published body silently drops this topic's own standing work.
      assert act.prompt =~ "--with-block-ids --working"
      assert act.prompt =~ "--base-revision-id"
    end
  end

  # The two presets offered against proposals. Where each is offered is decided
  # entirely by `resource_type`, so that is what these pin -- along with the
  # thing the conflict one exists to produce, which is a proposal of its own.
  describe "the proposal presets" do
    test "both ship against proposals" do
      outcomes = Presets.seed()

      assert {:created, conflict} = outcome_for(outcomes, "提案冲突处理")
      assert conflict.resource_type == "proposal"
      assert conflict.icon == "sparkles"
      assert conflict.prompt == conflict.default_prompt

      assert {:created, review} = outcome_for(outcomes, "提案评审")
      assert review.resource_type == "proposal"
      assert review.icon == "clipboard-check"
      assert review.prompt == review.default_prompt
    end

    test "the conflict one talks first and proposes only after that" do
      # The preset is two halves and the order is the whole design: the model
      # says what the disagreement turns on and stops, and only once a person
      # has settled it does an extra candidate get put up. A prompt that lost
      # the pause would propose into an argument nobody had finished having.
      {:created, conflict} = outcome_for(Presets.seed(), "提案冲突处理")

      assert conflict.prompt =~ "这一步不提案"

      # And the second half, which is where the command lives: N conflicting
      # proposals in, one more out, on the block they are arguing over. Losing
      # the command or the block scope would leave it answering in prose.

      assert conflict.prompt =~ "rinto-pmo doc propose"
      assert conflict.prompt =~ "--block"
      assert conflict.prompt =~ "--base-revision-id"

      # Real ids come from a read; the `[block:b1]` in the expansion is a label.
      assert conflict.prompt =~ "--with-block-ids"

      # The command is four lines joined by shell continuations. A single `\`
      # in the source would be a *heredoc* continuation instead, folding the
      # example onto one line and eating the backslashes on the way.
      assert conflict.prompt =~ "<document-id> \\\n"
    end

    test "the review one writes nothing and says so" do
      {:created, review} = outcome_for(Presets.seed(), "提案评审")

      refute review.prompt =~ "rinto-pmo doc propose"
      assert review.prompt =~ "只做评审"
    end

    test "an installation that predates them gets the rows, and its others are left alone" do
      # What an older deploy left behind: every preset except these two.
      outcomes = Presets.seed()
      {:created, conflict} = outcome_for(outcomes, "提案冲突处理")
      {:created, review} = outcome_for(outcomes, "提案评审")
      {:ok, _gone} = PromptShortcuts.delete_shortcut(conflict)
      {:ok, _gone} = PromptShortcuts.delete_shortcut(review)

      again = Presets.seed()

      assert {:created, back} = outcome_for(again, "提案冲突处理")
      assert back.prompt == conflict.prompt
      assert {:created, _review} = outcome_for(again, "提案评审")

      # The upgrade writes those two rows. Anything else moving would mean a
      # deploy bumping `updated_at` on rows it had nothing to say about.
      assert Enum.count(again, &match?({:created, _shortcut}, &1)) == 2
      assert Enum.count(again, &match?({:unchanged, _shortcut}, &1)) == length(Presets.all()) - 2
    end

    test "a reworded one keeps its wording, and reset hands back what shipped" do
      {:created, shipped} = outcome_for(Presets.seed(), "提案冲突处理")

      {:ok, _edited} = PromptShortcuts.update_shortcut(shipped, %{"prompt" => "我自己写的融合要求"})

      assert {:default_only, kept} = outcome_for(Presets.seed(), "提案冲突处理")
      assert kept.prompt == "我自己写的融合要求"

      assert {:ok, reset} = PromptShortcuts.reset_shortcut(kept)
      assert reset.prompt == shipped.prompt
    end
  end

  # A shortcut is one resource_type, so auto-resolving conflicts is two buttons:
  # the cited proposals, or every remaining argument on the document. What they
  # share is the missing pause -- they propose a merge without waiting to be
  # told which way to go, which is the whole difference from "提案冲突处理".
  describe "the auto-resolve conflict presets" do
    test "one ships against proposals, the other against documents" do
      outcomes = Presets.seed()

      assert {:created, cited} = outcome_for(outcomes, "解决冲突")
      assert cited.resource_type == "proposal"
      assert cited.icon == "git-merge"
      assert cited.prompt == cited.default_prompt

      assert {:created, whole} = outcome_for(outcomes, "解决所有冲突")
      assert whole.resource_type == "document"
      assert whole.icon == "layers"
      assert whole.prompt == whole.default_prompt
    end

    test "neither waits for a direction" do
      outcomes = Presets.seed()
      {:created, cited} = outcome_for(outcomes, "解决冲突")
      {:created, whole} = outcome_for(outcomes, "解决所有冲突")

      # The pause is the other preset. Losing this half would turn auto-resolve
      # back into a conversation, and the button would stop meaning what it says.
      refute cited.prompt =~ "这一步不提案"
      refute whole.prompt =~ "这一步不提案"
      assert cited.prompt =~ "不要等我确认"
      assert whole.prompt =~ "不要等我确认"
    end

    test "the proposal one proposes on the cited conflict" do
      {:created, cited} = outcome_for(Presets.seed(), "解决冲突")

      assert cited.prompt =~ "rinto-pmo doc propose"
      assert cited.prompt =~ "--block"
      assert cited.prompt =~ "--base-revision-id"
      assert cited.prompt =~ "--with-block-ids"
      assert cited.prompt =~ "不要 adopt"
      assert cited.prompt =~ "<document-id> \\\n"

      # It merges what was cited, not every argument on the document.
      refute cited.prompt =~ "rinto-pmo doc contentions"
    end

    test "the document one finds every conflict before it proposes" do
      {:created, whole} = outcome_for(Presets.seed(), "解决所有冲突")

      # Rival wording is not in the cited document, and `--working` withholds it.
      # Without these two reads the preset would be guessing from ids.
      assert whole.prompt =~ "rinto-pmo doc contentions"
      assert whole.prompt =~ "rinto-pmo doc proposal <document-id>"
      refute whole.prompt =~ "rinto-pmo doc proposals"

      assert whole.prompt =~ "rinto-pmo doc propose"
      assert whole.prompt =~ "--block"
      assert whole.prompt =~ "--base-revision-id"
      assert whole.prompt =~ "--with-block-ids --working"
      assert whole.prompt =~ "不要 adopt"
      assert whole.prompt =~ "<document-id> \\\n"
    end
  end

  describe "Presets.seed/0" do
    test "creates every preset the first time" do
      outcomes = Presets.seed()

      assert length(outcomes) == length(Presets.all())
      assert Enum.all?(outcomes, &match?({:created, _shortcut}, &1))

      for {:created, shortcut} <- outcomes do
        assert shortcut.prompt == shortcut.default_prompt
        assert shortcut.default_prompt != nil
      end
    end

    test "writes nothing when the row already says what this release says" do
      [{:created, preset} | _rest] = Presets.seed()

      assert {:unchanged, same} = Presets.seed() |> hd()

      # The point of the branch: this runs on every deploy, and an
      # unconditional update would leave `updated_at` saying "changed today"
      # on every row forever.
      assert same.updated_at == preset.updated_at
    end

    test "an untouched row follows the new default" do
      [{:created, preset} | _rest] = Presets.seed()
      shipped = preset.prompt

      # What the row would look like had it been seeded by an older deploy:
      # untouched, so both columns still agree.
      {:ok, _older} =
        PromptShortcuts.update_preset(preset, %{prompt: "旧的默认", default_prompt: "旧的默认"})

      assert {:followed, followed} = Presets.seed() |> hd()
      assert followed.prompt == shipped
      assert followed.default_prompt == shipped

      # Still equal, so the next deploy will move it again. This is the whole
      # point of updating both columns rather than only the default.
      assert followed.prompt == followed.default_prompt
    end

    test "an edited row keeps its wording and gets the new default underneath it" do
      [{:created, preset} | _rest] = Presets.seed()
      shipped = preset.prompt

      {:ok, _edited} =
        PromptShortcuts.update_preset(preset, %{prompt: "我自己写的", default_prompt: "旧的默认"})

      assert {:default_only, kept} = Presets.seed() |> hd()
      assert kept.prompt == "我自己写的"
      assert kept.default_prompt == shipped

      # And reset now hands over the *new* default, not the one it was seeded
      # with -- which is how an edited row catches up when it wants to.
      assert {:ok, reset} = PromptShortcuts.reset_shortcut(kept)
      assert reset.prompt == shipped
    end

    test "never writes the label or the icon again" do
      [{:created, preset} | _rest] = Presets.seed()

      {:ok, _renamed} =
        PromptShortcuts.update_shortcut(preset, %{"label" => "我的名字", "icon" => "my-icon"})

      Presets.seed()

      renamed = PromptShortcuts.get_shortcut!(preset.id)
      assert renamed.label == "我的名字"
      assert renamed.icon == "my-icon"
    end

    test "brings back a preset somebody deleted, which is why it is run by hand" do
      [{:created, preset} | _rest] = Presets.seed()
      {:ok, _gone} = PromptShortcuts.delete_shortcut(preset)

      assert {:created, back} = Presets.seed() |> hd()
      assert back.key == preset.key
      refute back.id == preset.id
    end

    test "deletes a shipped shortcut this release no longer carries" do
      # What an older deploy left behind: a button that used to ship and
      # does not any more. Including a reworded one -- taking the button
      # away is the decision, not freezing its last wording.
      {:ok, leftover} =
        PromptShortcuts.insert_preset(%{
          key: "tdyofk22eb5h5ndf",
          resource_type: "annotation",
          label: "梳理批注",
          icon: "message-square",
          prompt: "我自己写的分诊",
          default_prompt: "旧的分诊"
        })

      outcomes = Presets.seed()

      assert {:removed, removed} = outcome_for(outcomes, "梳理批注")
      assert removed.id == leftover.id
      assert PromptShortcuts.get_shortcut_by_key("tdyofk22eb5h5ndf") == nil
    end

    test "does not delete a shortcut somebody created themselves" do
      {:ok, custom} = PromptShortcuts.create_shortcut(attrs(%{"label" => "我的"}))

      Presets.seed()

      assert PromptShortcuts.get_shortcut!(custom.id).label == "我的"
    end

    test "the breakdown preset's preamble convention survives filing" do
      # The breakdown preset asks for a `rinto://` line above the first `##`,
      # to leave the source reachable from what was derived from it. That only
      # costs nothing if the filer ignores it -- so this pins the assumption
      # the prompt is written against.
      markdown = """
      从 [上线流程](rinto://document/01a06d44-c193-7a87-b31a-74ab60726db5) 拆出。

      ## 灰度发布

      ### 接入十分之一流量

      先切 10% 流量。

      - 错误率不高于基线
      """

      {:ok, contents} = Markdown.split(markdown)
      blocks = Enum.map(contents, &%DocumentBlock{content: &1})

      assert {:ok, [chunk]} = Breakdown.parse(blocks)
      assert chunk.title == "灰度发布"
      assert [%{title: "接入十分之一流量"}] = chunk.tasks
    end
  end

  describe "list_shortcuts/0" do
    test "answers with the whole set, oldest first" do
      # UUIDv7 ordering is only chronological across different milliseconds.
      # Insert fixed IDs in reverse order so this does not depend on clock speed.
      two =
        %PromptShortcut{id: "01900000-0002-7000-8000-000000000000"}
        |> PromptShortcut.changeset(attrs(%{"label" => "二"}))
        |> Repo.insert!()

      one =
        %PromptShortcut{id: "01900000-0001-7000-8000-000000000000"}
        |> PromptShortcut.changeset(attrs(%{"label" => "一"}))
        |> Repo.insert!()

      assert Enum.map(PromptShortcuts.list_shortcuts(), & &1.id) == [one.id, two.id]
    end
  end
end
