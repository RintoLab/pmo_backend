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

  Three presets write. "拆成任务" creates a document, which `rinto-pmo doc create`
  has always been able to do, and its prompt spells the command out because
  the shape of what it files is the whole point of the preset. "提案冲突处理" ends in a
  proposal of its own, and names `rinto-pmo doc propose` because the shape it
  has to produce -- one more candidate, on the block the cited ones are arguing
  over -- is the preset. It writes only after the person has settled which way
  to go, which is the second half of the same prompt. The rest answer in prose.

  ## A shortcut is a starting point, not a workflow

  There was a "回复批注" here that answered notes in their threads. It was
  removed (Kenton, 2026-09-05): once a topic has the CLI and the skill, asking
  for the answers to be written in is an ordinary sentence, and a button is
  worth having only for the thing you would not otherwise think to ask for.

  `rinto-pmo doc annotation-reply` is still there and is still how it happens.
  What went away is the click, not the capability -- which is the general
  shape: reserve a preset for the prompt somebody would not write from scratch.

  There was a "梳理批注" that triaged the same notes: still standing, whose
  job, whose duplicate. It was removed (Kenton, 2026-09-13) for the same
  reason -- that sentence is one you would write from scratch.

  "按批注提案" is the same topic and passes that test where the reply one
  failed. "照这几条批注改一下" is an ordinary sentence; what is not is the half
  page deciding which of them may be acted on at all -- a note that names a
  problem without naming a fix, or that is really a question waiting on
  somebody, gets a guess proposed against it otherwise, and a wrong proposal
  costs more to unpick than a missing one.

  Every write here has the command it needs. That was the constraint the order
  of this file was built around, and it is still met.

  ## Removing one

  Deleting the entry above is the whole act. `seed/0` upserts what is here,
  then deletes every shipped row (`default_prompt` is not null) whose key is
  no longer in the list. A button this release does not carry must not survive
  the deploy that dropped it -- including one somebody had reworded, because
  the decision was to take the button away, not to freeze its last wording.

  A row created through the API is not a shipped row and is left alone.

  The old reason not to reap -- a mistyped key literal silently destroying a
  prompt somebody had tuned -- is still a reason to copy a key rather than
  invent one when rewording. It is no longer a reason to leave a retired
  button in the composer until somebody deletes it by hand.
  """

  alias RintoPMO.PromptShortcuts
  alias RintoPMO.PromptShortcuts.PromptShortcut

  @typedoc """
  What running the task did to one row.

    * `:created` -- there was no row with this key
    * `:followed` -- the row was untouched, so its prompt took the new default
    * `:default_only` -- the row had been edited, so only its default moved
    * `:unchanged` -- the row already said what this release says
    * `:removed` -- a shipped row whose key is no longer in this release

  `:unchanged` writes nothing, which is the point of having it: this runs on
  every deploy, and an unconditional update would push `updated_at` forward on
  every row every time, leaving the column saying "changed today" forever.
  """
  @type outcome ::
          {:created, PromptShortcut.t()}
          | {:followed, PromptShortcut.t()}
          | {:default_only, PromptShortcut.t()}
          | {:unchanged, PromptShortcut.t()}
          | {:removed, PromptShortcut.t()}
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
      key: "tiqkolltvkaa6n7q",
      resource_type: "document",
      label: "审阅文档",
      icon: "file-search",
      prompt: """
      You are reviewing design documents for a team that has to build from \
      them. The documents referenced in this message are the ones to review.

      Read all of them before writing anything. Then report what is wrong, as \
      notes left on the documents.

      ## Review the set, not each one in turn

      The findings worth the most are the ones no single document contains -- \
      two documents that cannot both be true -- and reviewing them one after \
      another puts the comparison back on whoever asked. One document is a set \
      of one.

      ## What is worth reporting

      - **Contradictions.** Two places that cannot both be true. Across \
      documents is the most valuable kind: you were given them together because \
      nobody reading one alone would find it.
      - **Decisions that were never made.** A design that names a mechanism \
      without saying what it does in the case that will actually happen.
      - **Statements that will mislead somebody building from this**, including \
      text that has been overtaken by a decision recorded elsewhere in what you \
      were given.
      - **Gaps that matter.** Not everything absent is a gap; a document is \
      allowed to have a scope.

      What is not worth reporting: wording, tone, formatting, section order, or \
      anything you would preface with "consider". Nobody asked for this in \
      order to be told a paragraph could be tightened.

      ## Rules

      - **At most 12 findings.** If you have more, report the ones that would \
      cost the most to discover later. Somebody has to read every one of these \
      and decide about it, and forty notes on a document sized for the handful \
      a person leaves is a workspace nobody can use.
      - Each finding stands alone: say what is wrong and why it matters. Do not \
      number them, do not refer to "the previous point", do not write a summary \
      finding.
      - **Say the problem, not the edit.** A note cannot change the document \
      and nothing you write will be applied -- somebody reads each of these and \
      decides. Wanting a change is a separate request, made in this topic.
      - Write in the same language as the document.
      - **Nothing wrong is a real answer.** Say so and leave no notes, rather \
      than filling a quota.

      ## Getting the block ids

      The documents in this prompt mark their blocks `[block:b1]`, `[block:b2]`
      -- those are labels for reading, **not ids**. Before annotating a
      document, get its real ids:

          rinto-pmo doc show <document-id> --with-block-ids

      Never invent one. A block id that is not in the document leaves the note \
      unanchored -- the command says so when it happens, and a note that lost \
      its anchor is a note nobody can place.

      ## Leaving each finding

      One call per finding, on the document that should change:

          rinto-pmo doc annotate <document-id> \\
            --block <block-id> \\
            --body finding.md

      Omit `--block` only when the finding is about the document as a whole.

      When two documents contradict each other, decide which one is wrong, put \
      the note there, and cite the other in the text as \
      `[its title](rinto://document/<its id>)` -- that is a live link in this \
      system, so use the id you were given and nothing else.

      Read what each call prints. It tells you where the note landed, and \
      "unanchored" means the block id was wrong.

      When you are done, say how many notes you left and on which documents, or \
      say that you found nothing. Do not paste the findings back into the \
      conversation -- they are on the documents now.
      """
    },
    %{
      key: "rxt67rwqqi4d34ls",
      resource_type: "annotation",
      label: "按批注提案",
      icon: "file-pen",
      prompt: """
      我引用的是文档上的批注，同一条消息里还有它们所在的文档。把这些批注变成提案
      —— **但只在你确定该怎么改的时候。**

      ## 先逐条判断：清楚，还是存疑

      每条批注带着 `block:`（写这条批注时那一段的样子）、`selected:`（它指着的那
      句话）、批注正文，以及底下已有的回复。

      一条批注**清楚**，是指照它改只有一种做法，而且改出来的东西不取决于任何还没
      人拿的主意。这种直接提。

      下面任何一条成立就是**存疑**，先别提：

      - 它说了这里不对，但没说该成什么样，而合理的改法不止一种，几种改法做出来的
        东西还不一样
      - 它要的改动会牵动这一段之外：文档别处还在按旧的说，或者它改掉的是别处依赖
        的决定
      - 它和另一条批注要的方向相反
      - 它其实是个问句，在等人拿主意 ——「这里要不要保留 X」不是一条修改要求
      - `block:` 的锚文本和文档现在的正文对不上：这一段后来被人改过，批注指的问题
        可能已经不在了
      - 它底下的回复得出的结论和批注本身要的不一样

      **看不懂一条批注在说什么，就是存疑。** 顺着字面猜一个改法提上去，比不提更糟。

      同一件事有好几种写法但结果一样 —— 那不叫存疑，挑一种写就是了。

      ## 清楚的那些：提上去

      先读回文档，一次拿到真的 block id 和 `base_revision_id`：

          rinto-pmo doc show <document-id> --with-block-ids --working

      `--working` 不能省。`doc show` 给的是已发布的正文，不含你自己挂着的提案，
      拿它去改等于把上一轮的改动当成没提过，而且不会报错。提示词里的 `[block:b3]`
      是给人读的标签，**不是 id**。

      **默认传整篇：**

          rinto-pmo doc propose <document-id> \\
            --body revised.md \\
            --base-revision-id <上面读到的值> \\
            --change-summary "按 N 条批注修改"

      服务端自己算差异，把这一轮拆成一条条独立的提案 —— 改一段是一条，加一段是一
      条，删一段是一条。这正是这里要的：我可以只接受其中两条。而且加一节、删一节、
      拆一节、调顺序，只有整篇输入表达得出来。

      改动确实只落在一段、而且你已经知道是哪一段，才用：

          rinto-pmo doc propose <document-id> \\
            --block <block-id> \\
            --body one-section.md \\
            --base-revision-id <上面读到的值>

      响应里的 `superseded` 非空，说明本轮撤下了你上一轮的某些提案 —— 看一眼有没有
      漏掉仍然想保留的改动。

      ## 存疑的那些：问，不要提

      把问题问出来，并说清楚「答案不同会改出什么不同的东西」。答案不影响改法的问题
      不要问。

      **同一段里既有清楚的批注也有存疑的，那一段整个先别动**，连同清楚的那条一起
      问。半段先改出去，等答案回来又要重提一次，我看到的是两条互相打架的提案。

      **一条都不清楚就一条都不提。** 只问，不要为了有产出硬改一版。

      ## 规则

      - **不要确认批注。** 给批注盖章是我的动作。你能做的是提一条把它解决掉的改动，
        然后说这条提案对应那条批注。
      - 只做我引用的这几条。文档上还挂着别的批注不是这次的事，不要顺手一起做掉。
      - 一条批注指着哪一段就改哪一段，不要借机把整篇重写一遍。
      - **不要 adopt。** 提案是候选，选哪条是我的动作。
      - 用文档本身的语言写正文。

      ## 回话

      说清楚提了哪几条提案（id）、每条对应哪条批注；以及哪几条批注没提，各自卡在
      什么问题上。不要把正文贴回聊天里 —— 它们已经是提案了。
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
    },
    %{
      key: "2fj3dqkwanw23i3g",
      resource_type: "proposal",
      label: "提案冲突处理",
      icon: "sparkles",
      prompt: """
      我引用的这几条提案在争同一段正文，同一条消息里还有它们所属的文档。

      这件事分两步：**先跟我把冲突讲清楚，等我确认一个方向，你再提一条新提案。**
      不要跳过第一步。

      ## 第一步：这个冲突该怎么解

      读的时候两件事一起看：

      - 每条提案带三段文字。`<old>` 是它写作时那一段的样子，`<new>` 是它要改成
        的样子，`<current>` 只在正文后来又被人改过时才出现，那是这一段现在的
        样子。分歧在 `<new>` 之间，但一条基于旧正文写的提案，可能已经在解决一个
        不存在的问题了。
      - **整篇文档也在，用它。** 一段改写好不好，取决于它跟文档其余部分说不说得
        通：术语对不对得上、它改掉的决定别处是不是还在按旧的说、和前后两段还接不
        接得上。只盯着这一段比不出对错。

      然后回答这几件事：

      - **它们实际在争什么。** 不是把每条提案改了什么列一遍，是指出分歧收敛到的
        那一个点 —— 通常一句话讲得完：是要更严还是更松、是保留那个承诺还是删掉、
        是写给谁看的。
      - **侧重点是什么。** 这个选择真正取决于什么：这一段谁会读、下游哪个决定
        依赖它、选错了谁会受影响。把判断标准摆出来 —— 标准明说了，我才有办法不
        同意你。
      - **每条提案在这个标准下的得失。** 哪条抓住了要点、哪条顺手改了不该改的、
        哪条是从已经过时的正文改起的。
      - **你的建议。** 给一个我能直接答「就这个」的具体方向，不要摆三个并列选项
        让我挑。
      - **还需要我拿主意才能往下走的问题**，如果有。

      说完停下。**这一步不提案、不动文档。**

      ## 第二步：我确认之后，提一条新的

      我说了「就按这个」或者告诉你调整哪里之后，你再动手 —— 提的是**独立的一条新
      提案**，不是去改某条现有的。四条冲突提案进去，出来的是第五条，我在评审界面
      从这五条里选一条 adopt。

      取正文和真的 block id：

          rinto-pmo doc show <document-id> --with-block-ids --working

      两样东西都在这一次输出里：每一段真实的 block id，以及 `base_revision_id: ...`
      那一行。提示词里的 `[block:b1]` 是给人读的标签，**不是 id**，编一个出来不会
      报错，只会把提案挂到别处去。`base_revision_id` 原样传给下一步，不要另外查一
      个"最新的"顶上 —— 服务端靠它判断你这一版是从哪份正文改起的。

      把融合后的那一段写进文件，只写这一段，不是整篇：

          rinto-pmo doc propose <document-id> \\
            --block <block-id> \\
            --body merged.md \\
            --base-revision-id <上面读到的值> \\
            --change-summary "按讨论融合 N 条提案"

      **一个 block 只提一条。** 你这个话题在同一个 block 上只挂得住一条 live
      提案，再提一次是替换掉自己上一条，不是多一个候选。

      写正文时：

      - **综合的是主张，不是措辞。** 两条各对一半就各取一半；互斥就按确认的方向
        选一条。不要写一句把两边都装进去、于是什么都没说的话。
      - 不要为了显得公平而给每条都留一点痕迹。融合版要能独立读通，不是四条的拼贴。
      - 只动这一段。别的 block、文档标题、别人的提案都不是这次的事。
      - **不要 adopt，也不要试图撤下别人的提案。** 选哪一条是我的动作。
      - 用文档本身的语言写。

      提完说清楚新提案的 id、它落在哪一段，以及相对我确认的方向你在哪里做了取舍。
      不要把正文贴回聊天里 —— 它已经是一条提案了。

      ## 两种例外

      **它们其实不冲突** —— 落在不同 block，或者可以同时成立 —— 第一步就说清楚，
      不要为了交差硬融一版出来。

      **确实分属几个 block 各有各的争用** —— 按 block 分组，第一步一次把几组都讲
      完，第二步每组各提一条。不同 block 之间没有争用，不要揉进同一段文字里。
      """
    },
    %{
      key: "l6ju74xlltnyekgb",
      resource_type: "proposal",
      label: "提案评审",
      icon: "clipboard-check",
      prompt: """
      逐条读我引用的提案，给出评审意见，帮我决定每一条要不要采纳。

      每条提案带三段文字：`<old>` 是它写作时那一段的样子，`<new>` 是它要改成的
      样子，`<current>` 只在正文后来又被人改过时才出现，那是这一段现在的样子。

      对每一条说清楚：

      - **它实际改变了什么。** 对着 `<old>` 和 `<new>` 说差别，不是把 `<new>`
        复述一遍。改了一个决定、加了一个约束、删掉一段承诺，都要点名。
      - **值不值得采纳，为什么。** 给结论，不要列出"可以考虑的几个方面"。
      - **有没有我不看就发现不了的问题。** 重点是这三类：出现了 `<current>`，
        说明这一段已经被人改过，这条提案是不是在把那次修改覆盖掉；它改掉的东西
        文档别处还在按旧的说；它顺手改了标题、语气或结构，而那不是它声称要做的事。

      有几条落在同一处互相冲突的，放在一起说，并给一个倾向和理由 ——
      「都有道理，你定」不是评审意见。

      按「需要先决定的」排在前面。

      不要评论措辞、语气和格式。没有问题的提案就说没有问题，不要为了显得认真而
      给每条都挑一点毛病。

      **你现在只做评审。** 采纳、撤案、改文档都是单独的动作，要做了才做 ——
      想让我看一版融合的，那是另一件事。
      """
    }
  ]

  @doc """
  The presets, as data.
  """
  @spec all() :: [map()]
  def all, do: @presets

  @doc """
  Writes every preset, following the re-run rule above, then deletes every
  shipped row whose key is no longer in the list.
  """
  @spec seed() :: [outcome()]
  def seed, do: Enum.map(@presets, &seed_one/1) ++ reap_retired()

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

  def describe({:removed, shortcut}),
    do: ~s(removed "#{shortcut.label}" -- this release no longer ships it)

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

  defp reap_retired do
    shipped = MapSet.new(@presets, & &1.key)

    PromptShortcuts.list_shortcuts()
    |> Enum.filter(&retired?(&1, shipped))
    |> Enum.map(&reap_one/1)
  end

  defp retired?(%PromptShortcut{default_prompt: nil}, _shipped), do: false
  defp retired?(%PromptShortcut{key: key}, shipped), do: not MapSet.member?(shipped, key)

  defp reap_one(%PromptShortcut{} = shortcut) do
    case PromptShortcuts.delete_shortcut(shortcut) do
      {:ok, deleted} -> {:removed, deleted}
      {:error, changeset} -> {:error, shortcut.key, changeset}
    end
  end
end
