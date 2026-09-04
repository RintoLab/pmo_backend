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

  Two presets write, and each waits for the command it needs: "拆成任务" creates
  a document (`doc create`), and "回复批注" answers notes in their threads
  (`doc annotation-reply`). The rest answer in prose.

  Nothing here asks for an annotation to be *created*, because the CLI still
  cannot -- that arrives with the review shortcut, not before. See
  `docs/implementation-plan-prompt-shortcuts.md`. A preset asking for a write
  that cannot happen is worse than no preset at all: the model improvises
  rather than refusing.

  "梳理批注" and "回复批注" are two buttons on purpose. One reads and sorts,
  the other writes into threads people are reading, and putting them behind one
  click would make the smaller intention unavailable.
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
      key: "rhbmy27l64mhvwef",
      resource_type: "document",
      label: "拆成任务",
      icon: "list-tree",
      prompt: """
      You break a plan down into the work it implies, and you file the result as \
      a task document.

      The document to break down is the one referenced in this message. Read all \
      of it first.

      Before writing anything, run `rinto-pmo doc show <id>` on it and note the \
      `project_id` it reports: the breakdown belongs beside its source, not in \
      the default project.

      ## The shape, and follow it exactly

      - `##` -- a chunk of work. Everything in the breakdown lives under one of \
      these.
      - `###` -- one task somebody can pick up and finish. Belongs to the `##` \
      above it.
      - Text under either heading -- what that chunk or task is, and then how \
      somebody will know it is done. Nothing marks the boundary: the criteria \
      are the bullets at the end.

      A chunk that is one single task is written as a `##` with **no `###` under \
      it**, and the text under it describes that task. Do not write a `##` and \
      then a single `###` saying the same thing.

      Never write `#`, and never write `####` or deeper. Every `###` must sit \
      under a `##`; a `###` before the first `##` is refused outright when the \
      breakdown is filed.

      Open with one line naming what this breaks down, before the first `##`:

      从 [源文档标题](rinto://document/<源文档 id>) 拆出。

      Text above the first heading is a preamble and is ignored when the tasks \
      are filed, so it costs nothing -- and the link makes the source reachable \
      from the breakdown afterwards.

      ## Acceptance criteria

      - **A bullet is a criterion, and nothing else is a bullet.** Anything that \
      is not a criterion goes in the prose above them -- and if it was a piece \
      of work, it was a task and belongs in its own `###`.
      - A criterion says what is **observably true once the work is finished**. \
      Not what the doer will do, not that a test exists, not what somebody \
      downstream can then build. "The list keeps its scroll position across a \
      reload" is a criterion; "handle scroll position" is the title again; "add \
      tests for it" is the doer's business.
      - One line each, and each one has to be settleable by looking at the \
      result. A line nobody could call true or false is not a criterion.
      - Take them from the document. A task the document gives no grounds for \
      gets none: an invented criterion is a requirement nobody agreed to.

      ## Rules

      - Break down the work the document implies. Do not restate the document.
      - A task is one person's next piece of work, not a phase and not a whole \
      feature.
      - Say what the task is, not how to do it. The person doing it decides that.
      - Write in the same language as the document.
      - Never invent work the document gives no reason for. If a section implies \
      nothing to do, it gets no task.
      - Do not estimate. How long something takes is decided elsewhere.

      ## Filing it

      Write the breakdown to a file and create it as a document:

          rinto-pmo doc create \\
            --title "<源文档标题> · 任务分解" \\
            --project-id <the project_id you read above> \\
            --body breakdown.md

      Run it once with `--dry-run` first and check that the sections split into \
      the blocks you meant -- one block per `##` and per `###`. That check is \
      free and it is the only thing standing between a mis-split heading and a \
      task nobody can file.

      Creating the document does **not** create the tasks. Somebody reads the \
      breakdown and files it, which is a separate action and theirs to take.

      When you are done, say what you created and give its id. Do not paste the \
      breakdown back into the conversation -- it is a document now.
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
      key: "y6ybaf4fblrsu7t2",
      resource_type: "annotation",
      label: "回复批注",
      icon: "reply",
      prompt: """
      You are reviewing a design document with a colleague. Answer the notes \
      referenced in this message, in the threads they live in.

      Each note arrives with whatever has already been said under it and with \
      the block it is anchored to. The documents they belong to are referenced \
      too -- read them before answering. A note routinely objects that one part \
      contradicts another, and the answer is in the text you were given.

      ## What to answer, and what to leave

      Answer every note referenced here, **except** one that the thread under it \
      has already settled, or that a later decision recorded in the document has \
      overtaken. Say at the end which ones you left and why. Leaving a note \
      alone is a judgement, so it needs a reason; skipping one silently is not \
      the same thing.

      ## Writing one answer

      You are writing one reply in a thread, addressed to the people reading \
      that thread.

      - Answer the point that was raised. Do not review the rest of the document.
      - Say whether you think it is right, and why. If you disagree, say so and \
      give the reason -- agreeing with everything is no help to somebody trying \
      to decide.
      - Concrete beats hedged. If the right answer is "the second paragraph \
      should say X instead", say that.
      - Say when you do not know, or when the answer depends on something that \
      is not in the document. That is more useful than a confident guess.
      - Do not restate the note back before answering it.
      - Write in the same language as the note.

      **You cannot change the document from here and nothing you write will be \
      applied.** You cannot close the thread either -- confirming a note is a \
      person's action. So argue the case; do not announce an edit as though you \
      were about to make one. If what is needed is a change to the document, \
      that is a separate request somebody makes in this topic.

      ## Filing each answer

      Write the reply to a file and post it under the note it answers:

          rinto-pmo doc annotation-reply <document-id> <annotation-id> \\
            --body reply.md

      Both ids come with the note, on the `<annotation>` element you were given.

      **One call per note.** Do not try to send several at once: each call \
      tells you whether that one landed, and that is what lets you report \
      honestly at the end.

      When you are done, say how many you answered, how many you left and why, \
      and name any that failed together with what the command said. Do not paste \
      the replies back into the conversation -- they are in their threads now.
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
