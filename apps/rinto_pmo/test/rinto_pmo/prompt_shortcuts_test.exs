defmodule RintoPMO.PromptShortcutsTest do
  use RintoPMO.DataCase, async: true

  alias RintoPMO.PromptShortcuts
  alias RintoPMO.PromptShortcuts.Presets
  alias RintoPMO.PromptShortcuts.PromptShortcut

  defp attrs(overrides \\ %{}) do
    Map.merge(
      %{"resource_type" => "document", "label" => "通读文档", "prompt" => "读一遍。"},
      overrides
    )
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

    test "every preset asks only for prose, because the CLI cannot write annotations yet" do
      # A preset that told a model to run a command that does not exist would
      # get improvisation instead of a refusal. Remove this test in step 3 of
      # docs/implementation-plan-prompt-shortcuts.md, together with the
      # constraint it records.
      for preset <- Presets.all() do
        refute preset.prompt =~ "rinto-pmo", "#{preset.key} asks for a write that cannot happen"
      end
    end
  end

  describe "list_shortcuts/0" do
    test "answers with the whole set, oldest first" do
      {:ok, one} = PromptShortcuts.create_shortcut(attrs(%{"label" => "一"}))
      {:ok, two} = PromptShortcuts.create_shortcut(attrs(%{"label" => "二"}))

      assert Enum.map(PromptShortcuts.list_shortcuts(), & &1.id) == [one.id, two.id]
    end
  end
end
