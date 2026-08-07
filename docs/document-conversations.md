# Document Conversations

状态：**已实现**。三张表、并发话题、冷热与进程上限、`conversation` ref 均已落地。
API 见 `docs/api-frontend-guide.md`。

实现时补的洞：`message_refs` 增加 `position`，因为 `PromptBuilder` 按给定顺序展开 refs，
而 UUIDv7 只精确到毫秒，同一条消息的 refs 全落在一毫秒内、无法靠 id 还原顺序。
相关：`docs/document-annotations.md`（结论的落点）、`docs/document-working-session.md`（改文档的动作层）。

## 问题

`annotations` 承载的是**结论**：低频、人要读、永久留在文档上。
但 AI 协同审阅还需要一层**过程**：多轮推理、试探、澄清，高频、主要给 AI 自己读。

两者塞进同一张表，批注串会被聊天流水淹没；只留批注不留过程，则 AI 的审阅意见无处安放 ——
`Agent.PiSession` 是 `:temporary` 的 OS 进程，崩了或关了历史就没了，而 `pi_args/2` 传的是
`--no-session`，pi **自己不存**对话历史。

## 三层分工

| 层 | 是什么 | 频率 | 谁读 | 状态 |
|---|---|---|---|---|
| `annotations` (+replies) | 定点**结论/意见**，人机都能发 | 低 | 人 | 已实现，待加 status |
| `conversations` (+messages) | **过程**，多轮对话 | 高 | 主要 AI | 本文档 |
| working session → revision | 落到文档的动作 | 显式 commit | — | 已设计未实现 |

## 已拍板

### 归属

- conversation **不挂 `document_id`，也不挂 `annotation_id`**
  `Agent.PromptBuilder` 的 `compare 《A》 and 《B》` 就是跨文档对话；它不属于任何一个文档
- conversation 与 annotation 是**多对多**，且一个话题里的 annotation 会随聊天陆续加入
- 该关系由 `message_refs` 派生，**不建 `conversation_annotations` 关联表** ——
  那是 `message_refs` 的退化子集，还丢掉「何时被拉进上下文」，而重建 prompt 需要这个时间点
- refs 沿用 `PromptBuilder` 已有的类型：`document` / `annotation` / `project` /
  `attachment` / `proposal`，annotation 不特殊对待
- **`conversation` 不是对外的 ref 类型**（实现时拍板）。展开一条 ref 只渲染它自身及其
  从属部分、不跟随指向其他实体的指针，而对话是唯一无法遵守这条规则的形状 ——
  它的每条消息又带 refs。冷话题重开时的重放改为**后端在发送时注入、不写进 `message_refs`**：
  那是系统在恢复上下文，不是人在引用，记成引用会让话题每次醒来都引用自己一次

### 留档

- conversation **永久存储，但不永久呈现**
  - 存储：不删。它是唯一能回答「这段为什么改成这样」的东西，也是冷话题重开的唯一依据
  - 呈现：不出现在文档表面，入口是批注上的「看讨论过程」
- 真嫌多以后加 messages 保留策略，那是运维策略，不是 schema 决策，现在不定

### 消息内容

- messages 存**原始文本 + refs**，不存 `PromptBuilder` 拼好的 prelude
  replay 时按当时的文档状态重新展开，才不会把三周前的旧快照喂回去
- 单调 `position`（同 `annotation_replies` 的约定）
- 保留 `role`，尽管 `actor.kind` 也能推出来：replay 要的是喂给 pi 的原样，不是我们的归因

### 结论回写

- 一次聊天可能涉及 3 条批注、只解决其中 2 条，所以回写是**逐条**的
- `annotation_replies.source_message_id` 指向结论出自哪条消息，
  于是批注上看到结论 + 一个跳回对话对应位置的链接
- 没写回结论的批注保持 `status: open`，不因为「聊过了」而变化

## Schema

### conversations

- title, actor_id?（发起人）
- pi_session_id?（非空即「热」，见下）
- timestamps
- 无 document_id / annotation_id

### messages

- conversation_id, actor_id, role, content, position
- timestamps
- unique (conversation_id, position)；追加 position = max+1，删除不重排

### message_refs

- message_id, ref_type, ref_id, ref_document_id?
- index (ref_type, ref_id) —— 反查「这条批注被哪些话题聊过」
- `ref_document_id` 只为 annotation 服务：它只能经由文档访问（同 `PromptBuilder.resolve/1`）

### annotation_replies（增量）

- source_message_id?

## 并发话题

后端已具备：`PiSession.Supervisor` 是 `Registry`(unique) + `DynamicSupervisor`，
channel topic 为 `pi_session:<id>` 且离开不结束会话，命令的 reply 从独立进程发。
现在是线性的只因为 UI 只开一个。

### 一个话题一个 pi 进程

pi 进程内只有**一条**对话历史。docstring 说的「命令并发、按 id 关联」是并发**投递**，不是上下文隔离；
同进程跑两个主题会互相污染。故 **conversation : pi session = 1:1**。

### 冷热

- **热**：`pi_session_id` 非空且进程在跑
- **冷**：只有 DB 记录。点开时重建进程并 replay

> **修订（实现时拍板）**：冷转热**没有手动入口**，也不该有 —— 你不可能和一个冷对话对话，
> 所以正在被聊的话题按定义就是热的。**发第一条消息就是开热这个动作**。
> 相应地，WebSocket 频道按 `conversation:{id}` 寻址而不是按 pi 进程，
> 于是进程死掉时频道还在，客户端不必去查新的 session id。

必须有**活跃进程上限 + 空闲驱逐**，否则没有任何东西拦着开出几十个 pi 进程。
`PiSession.Supervisor.snapshot/0` 已按 `idle_ms` 倒序返回，正是 LRU 淘汰的输入。
超限就 close 最闲的，话题转冷。**话题数无上限，进程数有上限。**

replay 全量重放很贵：只重放最近 K 轮 + 重新展开该话题的 refs
（按**当前**文档状态展开，不是把旧快照喂回去 —— 在一个输出为整块替换的系统里，
基于陈旧文本写出的提案会静默覆盖掉期间的全部修改）。
重放中的 `conversation` ref 直接跳过，只展开一层。

## UI

### 布局：右栏两视图，不是第三栏

现状是 `[文档 | 批注列表]`。聊天**不新开一栏、不用弹窗**：
三栏挤扁文档，而聊文档时最需要看的就是文档；弹窗直接遮住它。

批注列表和对话窗几乎不需要同时全神贯注 —— 话题一旦建好，所涉批注已作为 refs 渲染在对话顶部。
故右栏是可切换的两个视图：`[批注] [话题 ②]`。

打开一个话题时，**左侧文档高亮该话题引用的批注锚点**（用已有的 `block_id` / `selected_text`）。
右栏虽被对话占满，文档上依然看得见「正在聊哪几处」。

### 屏幕上只有三处状态

1. 「话题」tab 角标 —— 需要你行动的话题数（等你回答 + 有结论待处理）
2. 文档上批注锚点的标记 —— 见下
3. 展开话题列表后每行的状态 —— 跑着 / 等你 / 闲置

没有第四处。**明确不要**：最小化气泡、toast、右侧悬浮卡片列。

理由：话题**没有位置**。一个话题引用分布在文档三处的批注，它的锚点是哪个？没有答案，
任何悬浮物都得在这件事上撒谎。有位置的（annotation）才上文档，没位置的（conversation）只待在右栏列表。

### 锚点标记：计数，不是入口

标记语义是「这条批注的状态」，不试图指向某一个话题，所以多对多天然成立：

| 样式 | 条件 |
|---|---|
| ○ 空心 | `status: open`，无活动 |
| ● 实心/脉冲 | 有话题在跑 |
| ❗ 高亮 | **有结论待你处理** ← 最强 |
| 无标记 | `resolved` / `dismissed` |

一条批注被 2 个话题讨论就显示数字 `2`；点开 popover 列出这些话题及各自状态，选一个右栏切过去。
反向：话题顶部的引用卡片点任一条批注 → 文档滚过去并高亮。两个方向都能导航，全程无悬浮元素。

### 标记的存亡由 status 决定，不由「读没读」决定

这是唯一容易做错的地方。若按「已读」清除，会出现：AI 聊完写回结论，你瞄一眼，
标记消失 —— 可批注根本没解决、文档也没改，它就这么从视野里没了。
而这恰恰是**最该你干预**的时刻。

故只有 `status` 变成 `resolved` / `dismissed`（你真做了决定）才清除。
讨论痕迹会从 ❗/● 退回 ○，不会一直亮着；○ 会堆积，但那不是噪音，是「你确实有 20 条没处理」。

### 「等你回答」不能省

`PiSession` 的 `pending_ui` **永不超时**。一个话题卡在等你回答，不去点就永远卡着，
进程也一直占着。这是并发设计里唯一不能省的 UI 元素。

## 生命周期

```
人/AI 建批注          → ○ open
选中 N 条开话题        → 首条消息的 refs 即这 N 条
聊起来                → ● 讨论中
AI 写回结论            → ❗ 待你处理（annotation_replies.source_message_id）
你改文档并 resolve     → 无标记；annotation 留档，
                        resolved_by_revision_id 指向那次修改
                        conversation 转冷，进程可回收，记录永久保留
```

## 明确不做

- 不建 `conversation_annotations` 关联表
- conversation 不挂 document_id / annotation_id
- 不把聊天流水写进 `annotation_replies`（只写结论）
- 不在 messages 里存展开后的 prelude
- 不做悬浮气泡 / 第三栏 / 弹窗
- 不做独立的 Reviews context —— 协同审阅 = 带 status 的 annotation + 挂在上面的 conversation，
  平行的第二套状态机只会带来同步噩梦（`lib/rinto_pmo/reviews/` 可删）
