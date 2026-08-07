# 实施计划：AI 协同审阅（批注状态 / 对话 / 提案）

给独立 AI 会话执行用。**先读 §1、§2，再动手。**

这份文档定的是**怎么落地**；**为什么这么设计**全在 §1 列的设计文档里，
遇到"这里为什么不那样做"一律回去查，不要自行改设计。
若发现设计文档之间矛盾或确有缺陷，**停下来报告，不要自作主张改**。

---

## 1. 先读设计文档

按顺序读，都在 `docs/`：

| 文档 | 定了什么 |
|---|---|
| `document-annotations.md` | 批注 = **结论**。status 生命周期 |
| `document-conversations.md` | 对话 = **过程**。三张表、多对话并发、冷热会话 |
| `document-working-session.md` | 改动 = **提案 → commit**。争用与裁决 |
| `ui-document-workspace.md` | 前端规格（本计划只做后端，但状态定义要对齐） |
| `ai-document-cli.md` | AI 写文档的**通道**（独立工作流，见 §6） |

三条贯穿性原则，实现中不得违反：

1. **人不直接写文档，人只做决定。** AI 写，人审、人选、人提交
2. **过程与结论分离。** 聊天流水进 `messages`，结论进 `annotation_replies`
3. **关系用派生的，别物化成实体。** 不建 `conversation_annotations` 这类关联表

---

## 2. 项目约定（必须遵守）

这是个 Elixir umbrella：`apps/rinto_pmo`（领域）+ `apps/rinto_pmo_web`（HTTP）。

### 2.1 新增 context 有六个接线点，缺一不可

项目用 Hammox + 依赖注入。**新建一个 context 必须同时改六处**，
漏掉任何一处的表现是编译过但测试炸，且报错信息不指向根因：

1. `apps/rinto_pmo/lib/rinto_pmo/<name>.ex` —— context 本体
2. `apps/rinto_pmo/lib/rinto_pmo/<name>/behaviour.ex` —— **每个公开函数一条 `@callback`**
3. `config/config.exs` 的 `:injectors` 加 `<name>: RintoPMO.<Name>`
4. `config/test.exs` 的 `:injectors` 加 `<name>: RintoPMO.<Name>Mock`
5. `apps/rinto_pmo/test/support/mocks.ex` 加 `Hammox.defmock(...)`
6. `apps/rinto_pmo/test/support/factory.ex` 加 factory

跨 context 调用**不要直接写模块名**，用 `RintoPMO.Utils.module(:name)`，
参考 `agent/prompt_builder.ex:326` 的 `defp documents, do: Utils.module(:documents)`。

⚠️ Hammox 会校验 `@callback` 与实现的类型是否一致。加了公开函数忘了加 callback，
或 spec 写得比实现宽，测试会失败。

### 2.2 Schema

```elixir
use RintoPMO, :schema        # 已带 UUIDv7 主键、utc_datetime_usec 时间戳
@type t :: %__MODULE__{}
```

参考 `annotations/annotation.ex`。changeset 用 `cast` + `validate_required` +
`foreign_key_constraint`，公开 `changeset/2` 和（需要时）`update_changeset/2`。

### 2.3 Migration

参考 `priv/repo/migrations/20260731115441_create_annotations_and_replies.exs`：

```elixir
create table(:foo, primary_key: false) do
  add :id, :binary_id, primary_key: true
  add :bar_id, references(:bars, type: :binary_id, on_delete: :delete_all), null: false
  timestamps(type: :utc_datetime_usec)
end
```

时间戳前缀必须大于现有最新的 `20260803075610`。

### 2.4 Web 层

- 控制器在 `apps/rinto_pmo_web/lib/rinto_pmo_web/controllers/v1/`，
  每个 `xxx_controller.ex` 配一个 `xxx_json.ex`
- 路由在 `router.ex` 的 `scope "/api/v1"` 内，嵌套资源照现有 documents/annotations 的写法
- 错误走 `FallbackController`
- **`openapi.yaml`（仓库根目录）必须同步更新** —— CLI 那条线以它为准

### 2.5 完成的定义

```
mix format
mix check      # compile --warnings-as-errors + deps.unlock --unused
               # + format --check-formatted + credo --strict + dialyzer + test
```

`mix check` 全绿才算完成。credo 是 `--strict`，dialyzer 也在里面，别留 spec 空洞。

---

## 3. 阶段划分

三个阶段**严格顺序执行**，每个阶段结束时系统都是可用、可交付的状态。

```
阶段 1  批注 status              独立，不依赖任何未实现的东西
   ↓
阶段 2  conversations 三张表      需要 actors/documents/annotations（都已存在）
   ↓
阶段 3  block_proposals + commit  需要阶段 2 的 conversation_id
```

**不要跳阶段，也不要合并阶段提交。** 阶段 2 的持久化接线是阶段 3 provenance 的前提。

---

## 4. 阶段 1：批注状态

### 目标

让「AI 聊完了，该我干预」这个状态在系统里可表达，让协同审阅能收敛。
设计依据：`document-annotations.md`。

### 改动清单

**Migration** `add_status_to_annotations`：

```
annotations
  + status                  :string, null: false, default: "open"
  + resolved_by_revision_id  references(:document_revisions, type: :binary_id,
                             on_delete: :nilify_all), null: true
  + index(:annotations, [:document_id, :status])
  + check constraint: status in ('open','resolved','dismissed')
```

**Schema** `annotations/annotation.ex`：
- `field :status, Ecto.Enum, values: [:open, :resolved, :dismissed], default: :open`
- `belongs_to :resolved_by_revision, DocumentRevision`
- **status 不进 `changeset/2` 和 `update_changeset/2` 的 cast 列表** ——
  它只能通过下面的专用函数变更，防止普通编辑顺手把状态改了

**Context** `annotations.ex` 新增（同步加 `behaviour.ex` 的 `@callback`）：

```elixir
resolve_annotation(annotation, attrs)   # attrs 可带 resolved_by_revision_id
dismiss_annotation(annotation)
reopen_annotation(annotation)           # 回到 :open，并清空 resolved_by_revision_id
```

`list_annotations/2` 的 `filter` 支持按 status 过滤。

**Web**：`annotation_controller.ex` 加动作，`annotation_json.ex` 输出 `status` 和
`resolved_by_revision_id`，router 加路由，`openapi.yaml` 同步。

**Factory**：`annotation_factory` 带默认 `status: :open`。

### 明确不做

- **不加 `annotation_replies.source_message_id`** —— 它引用 `messages`，那张表阶段 2 才有。
  留到阶段 2 一起做
- 不实现"有结论待处理"（★）的判定 —— 它依赖 `source_message_id`，同上
- 不碰 `create_revision` 路径

### 验收

- `resolve → reopen → resolve` 往返正确，`resolved_by_revision_id` 在 reopen 时被清空
- 普通 `update_annotation` 无法修改 status（写测试断言这一点）
- 按 status 过滤的列表接口有测试
- `mix check` 全绿

---

## 5. 阶段 2：对话持久化

### 目标

把聊天从"进程死了就没"变成可持久、可反查、可冷启。
设计依据：`document-conversations.md`。

### 5.1 三张表

新建 context `RintoPMO.Conversations`（走 §2.1 的六个接线点）。

```
conversations
  title            :string
  actor_id         references(:actors)         null: true   # 发起人
  pi_session_id    :string                     null: true   # 非空 = 热
  timestamps
  # 不挂 document_id / annotation_id —— 对话可跨文档，不属于任何文档

messages
  conversation_id  references(:conversations, on_delete: :delete_all)  null: false
  actor_id         references(:actors)                                 null: false
  role             :string   null: false      # user | assistant
  content          :text     null: false
  position         :integer  null: false
  timestamps
  unique_index(:messages, [:conversation_id, :position])
  check: position >= 0

message_refs
  message_id       references(:messages, on_delete: :delete_all)  null: false
  ref_type         :string  null: false        # document | annotation | project | attachment
  ref_id           :binary_id                  null: true
  ref_document_id  :binary_id                  null: true   # annotation 专用
  payload          :map     null: false        # 原始 ref map，原样存
  index(:message_refs, [:ref_type, :ref_id])
```

**关于 `payload`：** `PromptBuilder` 的 ref map 各类型键不统一 —— project 用 `"slug"`
不用 `"id"`（见 `prompt_builder.ex:141`）。所以**原样存一份 `payload`** 用于 replay，
同时把可索引的 `ref_type` / `ref_id` 规范化出来（project 写入时把 slug 解析成 id）。
两者用途不同，不要试图只留一个。

### 5.2 存什么、不存什么

- **存回合级，不存流式帧。** `message_update` 是高频增量，落库无意义。
  在 `message_end` / `turn_end` 时把拼好的整条消息写一次
- **存原始文本 + refs，不存 `PromptBuilder` 拼好的 prelude。**
  replay 时按当时的文档状态重新展开，否则会把旧快照喂回去
- `position` 单调递增，追加 = max+1（同 `annotation_replies` 的约定）

### 5.3 持久化接线

`PiSessionChannel` 现在什么都不写。需要新增一个 **per-conversation 的持久化进程**：

- 订阅 `PiSession.topic(session_id)`，消费 `{:event, frame}`
- 累积 `message_start` → `message_update` → `message_end`，在边界处写库
- 用户消息在 `handle_in("prompt", ...)` 成功后写（连同 refs）

**为什么单独一个进程，不写在 channel 里**：同一个会话可能被多个 channel（多标签页）
join，写在 channel 里会重复写。也不写在 `PiSession` 里 —— 它是 transport，
docstring 明确它只做进程管理和帧转发，不该有 DB 依赖。

### 5.4 冷热与会话上限

**这一条不做就会出事**：现在没有任何东西拦着开出几十个 pi 进程。

- `conversations.pi_session_id` 非空且进程存活 = 热；否则冷
- 活跃会话数上限（可配置，建议默认 8）
- 超限时驱逐最闲的：`PiSession.Supervisor.snapshot/0` 已按 `idle_ms` 倒序返回，
  直接拿来当 LRU 输入，然后 `PiSession.close/1`
- **有 `pending_ui` 的会话不驱逐** —— 它在等人，关掉等于丢掉那个问题
- 冷话题重开：新建 pi 进程 + replay。**只重放最近 K 轮**（建议 K=10，可配置）
  + 重新展开该话题的 refs，不要全量重放

### 5.5 顺带完成阶段 1 遗留

- Migration：`annotation_replies` + `source_message_id`
  （`references(:messages, on_delete: :nilify_all)`, null: true）
- `Annotations.create_reply/2` 支持传入 `source_message_id`
- 批注「有结论待处理」的判定现在可实现：
  `status == :open` 且存在 `source_message_id` 非空且晚于人最后一次查看的追评

### 5.6 PromptBuilder

加 `conversation` ref 类型：`%{"type" => "conversation", "id" => id}`，
展开成 `<conversation>` 元素（最近 N 轮）。照现有 `resolve/1` 的分支写法。

### 明确不做

- 不建 `conversation_annotations` 关联表 —— 多对多由 `message_refs` 派生
- `conversations` 不挂 `document_id` / `annotation_id`
- 不存流式帧
- 不做消息的编辑 / 删除（对话是过程记录，不可改）

### 验收

- 发一条带 3 个 refs 的消息，落库后 `message_refs` 有 3 行且 `payload` 可原样还原
- 「这条批注被哪些对话讨论过」的反查有测试，且走索引
- 杀掉 pi 进程后，历史消息仍可读；重开话题能恢复对话
- 超过上限时最闲的会话被驱逐，**且带 `pending_ui` 的不被驱逐**（写测试）
- `mix check` 全绿

---

## 6. 阶段 3：提案与提交

### 目标

让 AI 的改动可审、可选、可提交。设计依据：`document-working-session.md`。

### 6.1 block_proposals

```
block_proposals
  document_id       references(:documents, on_delete: :delete_all)      null: false
  block_id          :binary_id                                          null: false
  conversation_id   references(:conversations, on_delete: :nilify_all)  null: true
  content           :text     null: false
  base_revision_id  references(:document_revisions)                     null: false
  status            :string   null: false, default: "live"
  decided_by_actor_id  references(:actors)   null: true
  decided_at        :utc_datetime_usec       null: true
  timestamps
  check: status in ('live','accepted','rejected','superseded')
  unique_index(:block_proposals, [:block_id, :conversation_id], where: "status = 'live'")
  index(:block_proposals, [:document_id, :status])
```

最后那条**部分唯一索引**是"一话题一 block 一条活跃提案"的强制，是整个并发模型的地基。

`conversation_id` 用 `nilify_all` 而非 `delete_all`：**提案的生命周期不跟随话题**，
话题没了提案还在。

### 6.2 Documents.Session

`lib/rinto_pmo/documents/session.ex` + `session/supervisor.ex`（Registry + DynamicSupervisor，
参考 `agent/pi_session/supervisor.ex` 的写法）。

**per-document，一篇文档一个进程**（对比 `PiSession` 是 per-conversation）。

```elixir
start(document_id)                                  # 载入 latest revision + 活跃提案
propose(block_id, conversation_id, content)         # 已有活跃提案则就地更新
get_blocks(conversation_id)                         # base + 该话题自己的提案
                                                    # + "此 block 另有 N 条提案"
contentions()                                       # 活跃提案数 >= 2 的 block
decide(block_id, proposal_id, actor_id)             # 采用其一，其余转 rejected
commit(attrs)                                       # 落成 revision
discard()                                           # 提案留在库里
```

**进程不是真相来源**，`block_proposals` 才是。进程只是加速视图，崩了重建即可。
原设计文档里的 `document_drafts` 表不需要了。

### 6.3 争用

- 冲突判据就是**活跃提案数 ≥ 2**，不需要版本号、不需要锁
- **不做自动合并、不做 AI 自动重试**（设计文档明确否决，理由见那份的「明确否决」节）
- **不硬删提案**，只做 status 流转
- 裁决只有两个出口：选择其一 / 开新话题决定。**没有"手动融合"**

### 6.4 Commit

```
document_revisions + source_conversation_id  references(:conversations, on_delete: :nilify_all)
```

commit 一次做三件事，**必须在同一个 `Ecto.Multi` 里**：

1. 用选定提案创建新 revision（复用现有 `Documents.create_revision/2`）
2. 把勾选的批注标为 resolved，`resolved_by_revision_id` 指向本次 revision
3. 被采用的提案转 `accepted`，同 block 落选的转 `rejected`

其他规则：
- **存在未裁决争用的 block 拒绝提交**，但不阻塞其他 block
- 若 latest revision 已变，沿用现有 stale revision 冲突（不要静默重试或覆盖）
- **跨文档提交**：revision 是 per-document 的，一次提交 N 篇 = N 个 revision，
  由上层在一个事务里调用多个 session 的 commit。**不建跨文档的提交实体**

### 明确不做

- 不做 patch / diff 对象
- 不做每话题一份 working copy
- 不做 block 版本号 / 乐观锁 / 先写者优先
- 不给小改动开自动提交例外
- 不做 `document_drafts`

### 验收

- 两个 conversation 对同一 block propose → 该 block 进入争用，两条提案都是 `live`
- 同一 conversation 对同一 block propose 五次 → 始终只有一条 `live`（部分唯一索引生效）
- 带未裁决争用时 commit 被拒；裁决后可提交；**其余 block 不受影响**
- commit 后：revision 已建、批注已 resolved 且指向该 revision、提案状态已流转，
  **全部在一个事务里**（写一个中途失败的测试断言无部分写入）
- 杀掉 session 进程后提案仍在，重建进程能载回
- `mix check` 全绿

---

## 7. 与 CLI 工作流的关系

`docs/ai-document-cli.md` 是**并行的独立工作流**，本计划不包含它。两处交点：

1. 那份文档的第一阶段（`doc create`）**不依赖本计划**，可以先行
2. 那份文档的第二阶段（改已有文档）**依赖本计划的阶段 3** ——
   AI 的改动必须走 `block_proposals`，不能直接 `POST /revisions`

另外 `document_revisions.source_conversation_id` 要等本计划阶段 2，
在此之前 CLI 记不了 provenance，那是已知欠债。

---

## 8. 通用要求

- **每个阶段独立提交**，commit message 前缀 `feat:`
- 提交前跑 `mix test` 和 `mix check`，两个都过才提交
- 新增公开函数一律配 `@spec` 和 `@callback`（dialyzer + Hammox 都会查）
- `@moduledoc` 写清楚**为什么**这么设计，不要只复述函数名 ——
  参考 `agent/pi_session.ex` 和 `agent/prompt_builder.ex` 的写法，那是本项目的文档基调
- 遇到设计文档没覆盖的决策点：**先记下来问，不要自己定**

## 9. 已知欠债（不在本计划内）

- 新建文档没有 commit 闸门（`ai-document-cli.md` 认下的）
- `messages` 无保留策略 —— 永久存储，将来按需加
- 落选提案在长期运行后会累积 —— 同上，等有量了再定清理策略
- 跨文档话题的全局入口（UI 侧，`ui-document-workspace-edge-cases.md` §11 开放问题）
