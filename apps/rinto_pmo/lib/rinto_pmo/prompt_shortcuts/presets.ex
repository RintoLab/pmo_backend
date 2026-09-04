defmodule RintoPMO.PromptShortcuts.Presets do
  @moduledoc """
  The shortcuts this system ships with, and the rule for writing them again.

  ## Run by hand, not on boot

  `RintoPMO.Release.seed_prompt_shortcuts/0`. Deliberately not in
  `RintoPMO.Setup` and not called from `Application.start/2`: seeding
  resurrects a row somebody deleted, and whether that is the point or a bug
  depends entirely on whether a person asked for it. On boot it is a bug; typed
  into a deploy script it is the reason the command exists.

  ## Re-running

  Rows are matched by `key`, which is why the keys below are literals rather
  than something generated -- a fresh key each run would make every upsert an
  insert.

      field            | creating | running again
      -----------------+----------+-----------------------------------
      default_prompt   | write    | always overwrite
      prompt           | write    | only where it equalled default_prompt
      label/icon/type  | write    | never again

  The middle row is the whole design. An untouched shortcut has
  `prompt == default_prompt`, so it takes the new wording and *stays* equal --
  still untouched, still following whatever ships next. An edited one keeps its
  edit and gets the new default as what reset will hand it. One comparison
  therefore separates edited from untouched forever, which is why no `modified`
  column exists.

  The last row is a decision rather than an oversight: a label somebody renamed
  is theirs, and a deployment that renamed it back every time would be
  overruling the person using it. It also means `reset` puts back the prompt
  and leaves the name alone.

  ## What is here, and what is not yet

  Everything below answers in prose. Nothing tells a model to write to the
  database, because the only writing channel is the `rinto-pmo` CLI and it
  cannot yet create or answer an annotation -- see
  `docs/implementation-plan-prompt-shortcuts.md`. The shortcuts that replace
  document breakdown, annotation reply and document review arrive with the
  commands they need, not before. A preset that asks for a write that cannot
  happen is worse than no preset at all: the model improvises.
  """

  alias RintoPMO.PromptShortcuts
  alias RintoPMO.PromptShortcuts.PromptShortcut

  @typedoc """
  What running the task did to one row.

    * `:created` -- there was no row with this key
    * `:followed` -- the row was untouched, so its prompt took the new default
    * `:default_only` -- the row had been edited, so only its default moved
    * `:unchanged` -- the row already said what this release says

  `:unchanged` writes nothing, which is the point of having it: this runs on
  every deploy, and an unconditional update would push `updated_at` forward on
  every row every time, leaving the column saying "changed today" forever.
  """
  @type outcome ::
          {:created, PromptShortcut.t()}
          | {:followed, PromptShortcut.t()}
          | {:default_only, PromptShortcut.t()}
          | {:unchanged, PromptShortcut.t()}
          | {:error, String.t(), Ecto.Changeset.t()}

  @presets [
    %{
      key: "omzm37viwtmc6yl3",
      resource_type: "document",
      label: "通读文档",
      icon: "book-open",
      prompt: """
      通读我引用的文档，然后回答三件事：

      1. 这篇文档实际主张的结论是什么。不是复述目录，是它要人相信什么、要人照着做什么。
      2. 哪些地方悬而未决 —— 提到了一个机制但没说清真正会发生的那种情况该怎么办。
      3. 哪些地方读起来自相矛盾。

      不要评论措辞、语气、格式或章节顺序。没人是为了被告诉某段可以更紧凑才让你读的。

      如果这篇文档在你看来没有上述任何问题，就直接说没有，不要为了凑满三条而编。
      """
    },
    %{
      key: "tdyofk22eb5h5ndf",
      resource_type: "annotation",
      label: "梳理批注",
      icon: "message-square",
      prompt: """
      逐条读我引用的批注，以及每条下面已有的回复。对每一条说清楚：

      - 它提出的问题是否还成立，还是已经被后来的讨论或改动解决了
      - 如果还成立，需要谁做什么才算处理完
      - 它是不是其实和另一条在说同一件事

      按「需要先处理的」排在前面。

      **你现在只做分诊，不做处理。** 不要替我写回复正文，不要提议改文档 ——
      这两件事都要单独说了才做。
      """
    },
    %{
      key: "t6elkxibh4illfz4",
      resource_type: "task",
      label: "澄清任务",
      icon: "list-checks",
      prompt: """
      读我引用的任务。找出照着它开工之前必须先问清楚的问题。

      重点看这几类：

      - 完成的标准说得够不够具体，能不能判断什么时候算做完
      - 有没有隐含依赖别的任务或别人的决定，而任务里没写
      - 描述里有没有一个词可以有两种理解，而两种理解会做出不同的东西

      每个问题都要说清楚「答案不同会导致做出什么不同的东西」。
      答案不影响做法的问题不要问。
      """
    }
  ]

  @doc """
  The presets, as data.
  """
  @spec all() :: [map()]
  def all, do: @presets

  @doc """
  Writes every preset, following the re-run rule above.
  """
  @spec seed() :: [outcome()]
  def seed, do: Enum.map(@presets, &seed_one/1)

  @doc """
  One line describing what `seed/0` did to a row, for a deploy script to print.
  """
  @spec describe(outcome()) :: String.t()
  def describe({:created, shortcut}), do: ~s(created "#{shortcut.label}")

  def describe({:followed, shortcut}),
    do: ~s(updated "#{shortcut.label}" -- it had not been edited)

  def describe({:default_only, shortcut}),
    do: ~s(kept the edited prompt on "#{shortcut.label}"; its default is now the new one)

  def describe({:unchanged, shortcut}), do: ~s(left "#{shortcut.label}" alone -- already current)

  def describe({:error, key, changeset}),
    do: ~s(failed on #{key}: #{inspect(changeset.errors)})

  defp seed_one(preset) do
    case PromptShortcuts.get_shortcut_by_key(preset.key) do
      nil -> create(preset)
      %PromptShortcut{} = shortcut -> refresh(shortcut, preset)
    end
  end

  defp create(preset) do
    attrs =
      preset
      |> Map.take([:key, :resource_type, :label, :icon])
      |> Map.merge(%{prompt: preset.prompt, default_prompt: preset.prompt})

    tag(:created, preset, PromptShortcuts.insert_preset(attrs))
  end

  # Only ever the two prompt columns: label, icon and resource_type were
  # written when the row was created and belong to whoever has edited them
  # since.
  defp refresh(%PromptShortcut{} = shortcut, preset) do
    cond do
      # Nothing to say and nothing to write. Checked before the untouched test
      # so that a deploy does not bump `updated_at` on every row every time.
      shortcut.prompt == preset.prompt and shortcut.default_prompt == preset.prompt ->
        {:unchanged, shortcut}

      shortcut.prompt == shortcut.default_prompt ->
        tag(
          :followed,
          preset,
          PromptShortcuts.update_preset(shortcut, %{
            prompt: preset.prompt,
            default_prompt: preset.prompt
          })
        )

      true ->
        tag(
          :default_only,
          preset,
          PromptShortcuts.update_preset(shortcut, %{default_prompt: preset.prompt})
        )
    end
  end

  defp tag(outcome, _preset, {:ok, shortcut}), do: {outcome, shortcut}
  defp tag(_outcome, preset, {:error, changeset}), do: {:error, preset.key, changeset}
end
