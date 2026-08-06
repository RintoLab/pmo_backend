# Document Working Session

状态：**已实现**，模块名为 `RintoPMO.Documents.Session`。
`block_proposals` 取代了原设想的 `document_drafts`。API 见 `docs/api-frontend-guide.md`。

与本文档的差异：
- `block_proposals` 增加 `actor_id`（提案人）。`document_blocks.actor_id` 非空，
  提交时新 block 需要作者；用裁决人会把「AI 写的」变成「人批准的」
- 裁决只把落选方转 `rejected`，**赢家留在 `live`** —— 裁决不等于提交，
  `accepted` 只在 commit 时产生
- Session 进程**不缓存**：每个 context 函数都在自己的锁里重读，缓存只会变陈旧。
  即本文档「纯读缓存⋯⋯或先不缓存」的后者
- 提案只能改已有 block（schema 只有 `block_id` + `content`），暂不支持增删块
- `superseded` 状态无人产生 —— 设计文档未定义其语义，未自行发明
相关上下文：immutable document revisions + block snapshots。
产品取向：AI 改文档是核心；**不**以 Task 为主模型。
**结论**落在批注（`docs/document-annotations.md`），**过程 / 聊天历史**落在对话
（`docs/document-conversations.md`），**改动**落在本文档描述的 working copy → revision。
AI 用什么**通道**把改动送进来，见 `docs/ai-document-cli.md`。

## 贯穿性不变量

**人不直接写文档，人只做决定。**

AI 写，人审、人选、人提交。任何地方出现"让人手动编辑一段文本"的设计都要先质疑 ——
想要一个不同的版本，正确路径是去话题里说，由 AI 写出来。
这条是下面「争用出口只有两个」的依据，不要绕过它。

## 问题

AI agent 会在两个 revision 之间对文档做大量、频繁的 block 修改。
这些中间步骤**不应**每次都生成 revision；只有在明确愿意固化时才创建 revision。

Revision 历史应保持干净，只记录被认可的检查点。
聊天 / 过程历史落在**对话**（`conversations` / `messages`）中，而不是 Task；
批注只收**结论**。

## 结论

在两个 revision 之间需要一个 **working copy / session 层** 承载进行中的 blocks：

```
latest revision (DB, 不可变)
        ↓ 打开会话
working blocks（频繁被 AI 改，不生成 revision）
        ↓ 显式 commit
new revision（snapshot + base_revision_id）
```

这不是"revision 缓存"，而是**未提交的工作副本**。

不做 patch / diff 对象。理由：
- patch 会过期，两个话题针对同一 revision 各出一份必然冲突，而散文没有语义 merge
- patch 冻结迭代，而"再改一下这句"连说三遍是常态，每次重新生成再审三遍纯属自找
- diff 对散文没信息量：AI 改一段是整段重写，diff 只会说"这段全变了"

working copy 审的是**结果**不是每一步，迭代免费。

## 归属：一篇文档一份 working copy

**per-document，不是 per-conversation。** 所有话题共享同一份。

若每个话题一份 working copy，N 个话题就得到 N 份分叉的文档 —— 那才是真正的 merge 地狱，
比 patch 更糟。共享一份则不存在分叉，只需处理同一 block 上的争用（见下）。

分叉被压到了 **block 粒度**：文档只有一份，只有被多个话题同时改动的那些 block 才有分歧，
而分歧的解决方式是人做选择，不是文本 merge。

### provenance 是免费的

改动以**提案**形式存在，提案本身就带 `conversation_id`（见下节），
所以"这个 block 被哪几个话题碰过"不需要额外记录，是提案表的自然属性。

## 并发写与争用块

### 改动即提案，提案是持久化资源

AI 不直接改 working block，而是在 block 上留下一条**提案**（`block_proposals`）。

**提案的身份是 `(block, conversation)`，不是每次编辑一条。**
一个话题连着改同一段五次不该产生五条提案 —— 后面的就地覆盖前面的，
那是同一个意图在迭代。一个话题在一个 block 上最多一条活跃提案。

于是冲突判据极简，不需要任何锁或版本比对：

```
某 block 上活跃提案数 = 1  →  有改动，无争议
某 block 上活跃提案数 ≥ 2  →  争用，需裁决
```

### 为什么必须持久化

不是为了保险，是因为**「开个话题决定」这个出口要求提案可寻址**：
把两份提案喂进新对话靠的是 `message_refs`，而 ref 只能指向一个有 id 的资源，
指不了 GenServer 里的一团内存。只要保留那个出口，提案就必须落库。

附带解决本文档原先挂着的 TODO：`block_proposals` **就是那张 draft 表**，
会话进程崩了提案还在。

### base_revision_id 不能用作冲突判据

working copy 是 per-document 从 latest revision 载入的，
同一会话内所有话题的 base **按构造恒等**。它永远相等，因此没有鉴别力 ——
同 block 就是同 block，不存在"同 block 但不算冲突"的情况。

### 明确否决：AI 自动重试

曾考虑"后写的 AI 重读新文本后重新适配"。**否决。**

看似顺滑，实则把一个真实的语义决策偷偷交给了 AI：它会自行判断怎么把自己的意图
糅进别人改过的文本，产出一个**两个话题都没要求过的第三版**，
而这个决策没有任何人审过 —— 它发生在那个 AI 的一个 turn 内部。

也一并否决了随之而来的 block 版本号 / 乐观锁 / 先写者占住当前值那一整套机制：
提案模型下各话题写各自的槽，物理上不会互相覆盖，没有 race 需要检测。

### 读语义

每个话题读到的是 `base + 自己的活跃提案`，
另加一个事实：这个 block 上还有 N 条别的提案（内容可不给）。

让它知道有人在动这段，它可能就不会再往上堆第三个。

### 两个出口

| 出口 | 说明 |
|---|---|
| 选择其一 | 采用 A 或采用 B；落选方的话题被告知未采纳及原因 |
| **开个话题决定** | 建新话题，两份提案 + 两个来源话题作为 refs 喂进去 |

**没有"手动融合"**。见开头的不变量：想要第三版就去话题里说。

第二个出口是这套设计里最顺的一环 —— 争用本身就是个值得讨论的议题，
而讨论在本系统里已经是一等公民。喂进去的上下文是完整的：两版文本、各自出自哪个话题、
那些话题在解决哪些批注。

### 时机

- **立即标记**：文档上该 block 出现争用标记；涉及的话题都被告知存在争用
  - 是**告知**不是阻塞 —— 各话题写自己的槽，没有谁被挡住。
    但让它知道，好过让它在"我的版本一定会赢"的假设上继续推
- **不强制处理**：可以先去干别的
- **commit 时拦截**：带着未裁决的争用，不允许提交该 block

争用发生在 block 上，**它有位置，所以可以上文档**（同 `docs/ui-document-workspace.md` 的原则：
有位置的才上文档）。视觉权重与"有结论待处理"同级。

### Schema

```
block_proposals
  document_id, block_id, conversation_id
  content（或 ops）
  base_revision_id            ← 写这条提案时的基准；进程死了也还在
  status: live | accepted | rejected | superseded
  decided_by_actor_id?, decided_at?
  timestamps
  unique (block_id, conversation_id) where status = live
```

最后那条唯一约束就是"一话题一 block 一条活跃提案"的强制。

### 裁决后不硬删

**只做 status 流转，不 DELETE。** 三个理由：

1. 提案一旦被话题引用过，硬删就制造悬空引用，那个话题的 replay 会断 ——
   正是 `ui-document-workspace-edge-cases.md` §4 那个失效场景，等于在自己系统里主动制造它
2. **"为什么选了 A 不选 B" 是这套系统最值钱的记录。** 整个产品就是为了让协同审阅的
   决策有据可查，把落选方删掉等于扔掉一半理由
3. 真正想要的是它**从工作台视图消失**，不是从数据库消失 ——
   同 conversation 的"永久存储、不永久呈现"

真嫌多，等 revision 提交后按保留策略批量清理。那是运维策略，不是 schema 决策，现在不定。

## Commit

### 一次讨论改多篇文档

revision 是 **per-document** 的（`document_revisions` belongs_to `Document`）。
所以一次讨论改 N 篇文档 → **N 个 revision**。

**不引入跨文档的"提交"实体。** 跨文档原子提交在一个各文档独立编辑的系统里本就是假象。
「一次提交」只是 UI 概念：一个审核界面、一个按钮，底下在一个事务里写 N 个 revision。

回溯靠反查：revision 增加 `source_conversation_id`，
于是"这次讨论改了什么"是一个查询，不是一个存起来的实体。
（同 `message_refs` 的原则：关系用派生的，别物化成实体。）

### commit 是三件事的交汇点

1. 产生新 revision（`change_summary` 记这次改了什么）
2. **把相关批注标为 resolved，`resolved_by_revision_id` 指向本次 revision**
3. 相关话题收尾转冷

第 2 条尤其重要：没有 commit 这个动作，`annotations.status` 的 resolve
就没有一个自然的发生地点。所以 commit 界面应带「本次解决了：批注 1、批注 3」的勾选。

批注属于某篇文档，其解决它的 revision 必然在同一篇文档里，天然对得上。

### block 级取舍

commit 是逐 block 可取舍的，不是全有全无：

```
□ 段落 3   改动来自「术语对齐」
□ 段落 7   ⚠ 争用未裁决 —— 阻止提交
□ 段落 2   改动来自「术语对齐」        (接口文档)
```

这在 block 存储模型上是自然的（`BlockOps` 本就按 block 操作，revision 本就是全量 block 快照），
在文本 patch 模型上反而做不干净。

**默认全部勾选保留**，想退回的才动手 —— 一个闸门，但很轻。

### 不开自动应用的口子

不要为"小改动"（错别字之类）设自动提交例外。
一旦有例外，用户就得开始猜"这次是自动的还是要我审的"，信任从这里开始崩。
正确做法是让 commit 足够便宜，而不是让它可跳过。

## GenServer 是否合适

- **合适**：作为 **per-document** 的编辑会话进程
  - 串行 apply ops
  - 内存中持有 base blocks + 活跃提案的视图
  - `commit` 时再调用现有 `create_revision` 语义
- **不合适**：当作两个 revision 之间的唯一真相来源或通用读缓存
- **纯读缓存**更优先考虑 ETS，或先不缓存
- **持久化**：`block_proposals` 即 draft 表，进程只是它的加速视图，不是真相来源。
  原先设想的 `document_drafts` 不再需要

注意与 `Agent.PiSession` 的区别：那个是 **per-conversation**（一个话题一个 pi 进程），
这个是 **per-document**。两者不是一一对应，N 个话题会话可能同时对一个文档会话下 ops。

## 建议模块边界（以后实现时）

`Documents.Session`（名称待定）+ `DynamicSupervisor`：

- `start(document_id)`：从 latest revision 载入 blocks，记录 `base_revision_id`，
  载入已有的活跃提案
- `propose(block_id, conversation_id, content)`：写该话题在该 block 上的提案
  - 已有活跃提案则就地更新（一话题一 block 一条）
  - 返回该 block 当前的活跃提案数，供调用方判断是否已构成争用
- `get_blocks(conversation_id)`：供 AI 读取 —— `base + 该话题自己的提案`，
  另附"此 block 另有 N 条提案"的事实
- `contentions()`：列出活跃提案数 ≥ 2 的 block
- `decide(block_id, proposal_id, actor_id)`：采用其一，其余转 `rejected`
- `commit(attrs)`：把选定提案落成 revision
  - 存在未裁决争用则拒绝
  - 若 latest 已变，沿用现有 stale revision 冲突
  - 跨文档提交由上层在一个事务里调用多个 session 的 commit
- `discard()`：丢弃会话（提案留在库里，不随进程消失）

可选：

- 不要每步建 revision；防抖/显式 commit 即可

## 与当前存储模型的关系

当前每个 revision 仍是全量 block snapshot，相邻 revision 之间会有重复 block 行。
这是用存储换简单读取的取舍，与 session 层正交：

- session 解决的是：**高频中间编辑不要污染 revision 历史**
- 若以后要减存储冗余：可另做 content-addressed 去重或 delta，不必和 session 绑在一起

## 前提与风险

**争用方案依赖 block 粒度接近段落。**

若单个 block 很大（比如整节），两个话题改同一 block 的概率显著上升，且大多是**假冲突**
（改的是不同句子），争用界面会退化成骚扰。

block ≈ 段落时，"两个话题改同一段"确实罕见且有意义 ——
罕见所以打断人的成本低，有意义所以值得打断。若日后 block 粒度变粗，此方案需重新评估。

**认下的代价：working copy 不再是"一套 blocks"。**
读变成 `base + 该话题的提案`，比本文档原先假设的模型复杂一层。
换来的是：不需要锁、不需要版本号、不需要先写者优先、提案可被引用、进程可崩。判断是值。

**已知局限，不打算解决：** 话题 B 改了 block 3 和 block 7，其中对 block 7 的改法
依赖它对 block 3 的改动；若 block 3 裁决输了，block 7 可能不自洽。
逐 block 裁决天然如此，出口仍是「开个话题决定」。

## 明确不做

以下在实现中全部守住（前两条已随实现调整，其余不变）：

- ~~不实现 Session / GenServer~~ —— 已实现 `RintoPMO.Documents.Session`
- block snapshot 写入路径未改；`create_revision` 仅新增 `source_conversation_id`
  一个可选字段，commit 复用其内部的 `insert_revision`
- 不以 Task 承载 AI 改文档过程
- 不做 patch / diff 对象
- 不做每话题一份 working copy
- 不做 block 版本号 / 乐观锁 / 先写者占住当前值
- 不做争用的自动合并 / AI 自动重试
- 不做手动融合编辑
- 不硬删提案（只做 status 流转）
- 不做跨文档的提交实体
- 不给小改动开自动提交例外
- 不再需要 `document_drafts`（`block_proposals` 取代）
