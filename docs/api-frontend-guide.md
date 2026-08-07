# 前端对接指南

针对 `openapi.yaml` 描述的 `/api/v1`，补充**每个资源是什么、为什么这么设计、怎么用**。
字段级细节以 `openapi.yaml` 为准，两者冲突时以 `openapi.yaml` 和代码为准。

---

## 0. 全局约定

| 项 | 说明 |
|---|---|
| Base URL | `/api/v1`，开发环境 `http://localhost:4000/api/v1` |
| 格式 | 请求与响应均为 JSON；**仅附件上传**用 `multipart/form-data` |
| 认证 | **没有。** 全部接口公开，`Actor` 也不带任何认证字段 |
| 分页 | **没有。** 所有列表一次返回全部（详见 §11） |
| ID | UUIDv7 字符串。**按 id 升序即按创建时间升序**，可直接当排序键 |
| 时间 | ISO-8601，微秒精度，UTC |
| `PUT` / `PATCH` | 完全等价，`PUT` 只是别名，语义都是局部更新 |

### 响应包裹

单个资源与列表都包在 `data` 里：

```json
{ "data": { "id": "0193...", "...": "..." } }
{ "data": [ { "...": "..." } ] }
```

**两个例外**（`data` 之外还有兄弟字段）：
- `POST /documents/{id}/proposals` → 另有 `live_proposals`、`contended`
- `GET /ai_models` → 另有 `status`

### 错误

统一形状，HTTP 状态码 + 机器可读的 `error` + 面向人的 `message` + 结构化 `details`：

```json
{
  "error": "unresolved_contention",
  "message": "The block has competing proposals that nobody has decided.",
  "details": { "block_ids": ["0193..."] }
}
```

**请对 `error` 分支，不要对 `message` 分支** —— 后者是给人看的，措辞会变。

常用码：

| HTTP | `error` | 含义 |
|---|---|---|
| 400 | `bad_request` | 查询参数不合法（如 `status=nope`） |
| 404 | `not_found` | 资源不存在 |
| 409 | `stale_document` | 提交基准已过期，`details.current_revision_id` 给出当前值 |
| 409 | `unresolved_contention` | 选中的 block 有未裁决的争用 |
| 422 | `validation_error` | `details` 是 `{字段: [错误信息]}` |
| 422 | `unknown_block` / `nothing_to_commit` / `annotation_not_found` … | 见 §7 |

---

## 1. 先理解三层模型（最容易做错的地方）

这套系统把「AI 协同审阅」拆成三层，**互不代替**：

| 层 | 资源 | 是什么 | 频率 | 谁读 |
|---|---|---|---|---|
| **结论** | `annotations` + `replies` | 定点意见、决定 | 低 | 人 |
| **过程** | `conversations` + `messages` | 多轮推理、试探、澄清 | 高 | 主要是 AI |
| **改动** | `block_proposals` → `revision` | 对文档的实际修改 | 显式提交 | 人审、人选 |

贯穿性原则，UI 设计不要违反：

1. **人不直接写文档，人只做决定。** AI 写，人审、人选、人提交。
   任何「让人手动编辑一段正文」的交互都要先质疑 —— 想要另一个版本，正确路径是**去话题里说**
2. **过程与结论分离。** 聊天流水进 `messages`，结论进 `annotation_replies`。
   不要把聊天记录写进追评
3. **关系是派生的。** 「这条批注被哪些话题聊过」由 `message_refs` 反查，没有关联表

---

## 2. Actors（人与 AI 人格）

`GET|POST /actors`，`GET|PATCH|PUT /actors/{id}`（**无删除**）

一张表同时表示人和 AI，用 `kind` 区分：`human` | `ai`。这是刻意的 ——
批注、追评、消息、提案都由「某个 actor」产生，人和 AI 在这些地方**一视同仁**，
UI 不需要两套归因逻辑。

AI 专属字段：`provider`、`model`、`thinking_level`、`system_prompt`、`injection_profile`、`enabled`。
可用的 provider/model 取值来自 `GET /ai_models`。

`kind` 创建后不可改。

---

## 3. Projects / Repos / Credentials

- `GET|POST /projects`，`GET|PATCH|PUT|DELETE /projects/{slug}` —— **用 slug 定位，不是 id**
- `GET|POST /projects/{project_slug}/repos`，`GET|PATCH|PUT|DELETE /projects/{project_slug}/repos/{id}`
- `GET|POST /repo_credentials`，`GET|PATCH|PUT|DELETE /repo_credentials/{id}`

要点：

- `DELETE /projects/{slug}` 是**归档不是删除**：`status` 转 `archived`，返回 204，幂等。
  `GET /projects` 只列 active，`GET /projects/{slug}` 归档的也能取到
- `status` 不能通过 `PATCH` 改，只能用 `DELETE` 归档，且**不可恢复**
- 仓库是**只读**的 Git 引用，供 AI 读代码用；`last_synced_at` / `last_sync_error` 是同步状态
- **凭据的 `token` 永不返回**。响应只有 `id` / `name` / `username`

---

## 4. Documents & Revisions（文档与版本）

```
GET|POST /documents
GET|DELETE /documents/{id}
GET|POST /documents/{document_id}/revisions
GET      /documents/{document_id}/revisions/{revision_id}
```

### 模型

文档 = **稳定身份**（`documents`）+ **不可变版本链**（`document_revisions`）。
正文和标题都在 revision 里，文档本身只有 `project_id` 和归档状态。

每个 revision 是**全量 block 快照**，不是 diff。block 有两个 id：

- `block_id` —— **跨 revision 稳定**，标识「同一段」。批注、提案都锚在它上面
- 快照行自己的主键 —— 不对外暴露

### 读

- `GET /documents` → 每篇带 `latest_revision` 的**摘要**（无 blocks）。
  `?project_id={uuid}` 过滤，`?project_id=none` 只看未归属的。已归档的文档不出现
- `GET /documents/{id}` → `latest_revision` **带完整 blocks**（含 `block_id`、`content`、`position`、`actor_id`）

### 写

`POST /documents`：

```json
{
  "title": "项目计划",
  "project_id": "0193...",
  "change_summary": "初稿",
  "blocks": [{ "actor_id": "0193...", "content": "## 背景\n\n正文" }]
}
```

`POST /documents/{id}/revisions` —— **直接改文档的低阶通道**：

```json
{
  "base_revision_id": "0193...",
  "change_summary": "...",
  "block_ops": [
    { "op": "update",       "block_id": "...", "actor_id": "...", "content": "新正文" },
    { "op": "insert_after", "after_block_id": "...", "actor_id": "...", "content": "新段" },
    { "op": "move_after",   "block_id": "...", "after_block_id": "..." },
    { "op": "delete",       "block_id": "..." }
  ]
}
```

`after_block_id: null` 表示插到最前。`base_revision_id` 与最新不符 → `409 stale_document`。

> ⚠️ **AI 的改动不要走这个接口。** AI 必须走提案（§7）。
> 这条通道留给「人明确知道要改成什么」的场景，以及 CLI 建文档。

`DELETE /documents/{id}` 同样是**归档**，返回 204。

---

## 5. Annotations（结论层）

```
GET|POST         /documents/{document_id}/annotations
GET|PATCH|PUT|DELETE /documents/{document_id}/annotations/{id}
POST             /documents/{document_id}/annotations/{id}/resolve
POST             /documents/{document_id}/annotations/{id}/dismiss
POST             /documents/{document_id}/annotations/{id}/reopen
GET              /documents/{document_id}/annotations/{id}/conversations
POST             /documents/{document_id}/annotations/{annotation_id}/replies
PATCH|PUT|DELETE /documents/{document_id}/annotations/{annotation_id}/replies/{reply_id}
```

### 锚定

批注挂在**文档身份**上，不挂 revision —— 所以升版本不会丢批注。可选锚点：

- `block_id` —— 锚在哪一段（可空，表示整篇级批注）
- `block_text` / `selected_text` —— 创建时的**文本快照**，无位置偏移

正文变了之后快照对不上，是**正常现象**，UI 应据此提示「原文已改」而不是报错。

### status：三态，只有人能推动

`open`（默认）| `resolved`（采纳并已改文档）| `dismissed`（看过，决定不做）

**关键约束：`status` 不在创建和更新的 payload 里。** `POST` / `PATCH` 带上 `status` 会被静默忽略。
它只能通过三个专用动作变更 —— 目的是防止「编辑一下措辞」顺手把批注关掉。

| 动作 | 效果 |
|---|---|
| `POST .../resolve` | → `resolved`。可选 body `{"resolved_by_revision_id": "..."}` 记录是哪次修改解决的 |
| `POST .../dismiss` | → `dismissed`，**并清空** `resolved_by_revision_id`（没改文档，就没有 revision 解决它） |
| `POST .../reopen` | → `open`，**并清空** `resolved_by_revision_id` |

`resolved_by_revision_id` 非空 ⟺ `status == "resolved"`，可以放心依赖这个不变量。

**`dismissed` ≠ 删除。** 前者是「这条意见成立，但答案是不」，记录保留；
后者是「这条批注本来就不该存在」（贴错文档、重复提交），才用 `DELETE`。
删除会级联删掉全部追评，并让引用过它的话题指向空。

### 列表过滤

`GET .../annotations` 支持组合：

- `?block_id={uuid}` —— 某一段的；`?block_id=none` —— 无锚点的
- `?status=open|resolved|dismissed`
- `?pending_conclusion=true` —— **「有结论待你处理」**：`status=open` 且存在来自对话的追评

列表**不含**追评；`GET .../annotations/{id}` 才带全量追评（按 `position` 升序）。

### 追评

承载**结论**，不承载聊天流水。`position` 单调递增，**删除不重排**（会留空洞，正常）。
可选 `source_message_id` 指向结论出自哪条对话消息 —— UI 应据此提供「看讨论过程」的跳转。

### 锚点标记：四档

这是 UI 上最需要照做的一处：

| 样式 | 条件 | 数据来源 |
|---|---|---|
| ○ 空心 | `status=open`，无话题在跑 | `status` |
| ● 实心/脉冲 | 有话题正在讨论它 | `GET .../annotations/{id}/conversations` 里有 `hot=true` 的 |
| ❗ 高亮（最扎眼） | **有结论待处理** | `pending_conclusion=true` |
| 无标记 | `resolved` / `dismissed` | `status` |

> ⚠️ **不要按「用户看过了」清除标记。**
> 那会导致：AI 讨论完写回结论 → 用户瞄一眼 → 标记消失 ——
> 可批注根本没解决、文档也没改。而那恰恰是最需要用户处理的时刻。
> **只有 `status` 变成 `resolved`/`dismissed` 才清除。**

一条批注被 2 个话题讨论就在标记旁显示 `2`，点开列出这些话题。

---

## 6. Conversations & Messages（过程层）

```
GET|POST      /conversations
GET|PATCH|PUT /conversations/{id}
POST          /conversations/{id}/close
GET|POST      /conversations/{conversation_id}/messages
GET           /conversations/{conversation_id}/messages/{id}
```

### 话题不属于任何文档

`conversations` **没有** `document_id`，也**没有** `annotation_id`，所以它不在 `/documents/...` 下面。
理由：「对比《A》和《B》」是一个跨两篇文档的话题，它不属于其中任何一篇。

它涉及什么，由消息上的 `refs` 派生 —— 而且还保留了「**何时**被拉进上下文」这个信息，
这是关联表给不了的。

### 冷 / 热

| 字段 | 含义 |
|---|---|
| `pi_session_id` | 声称在承载这个话题的 pi 进程。**非空只是声称** |
| `hot` | **真的有活进程在跑**。派生字段，请用这个判断 |
| `replay_pending` | 刚起了新进程，下一条消息还欠它最近的对话。后端自理，前端只需知道这解释了为什么某次回复会慢 |
| `assistant_actor_id` | 这个话题**在跟哪个 AI 人格对话**。**没设的话发消息会被拒**（`assistant_actor_required`），所以建话题时就该带上 |

冷是**常态不是故障**：消息都还在，足以重建话题。
进程有数量上限（默认 8），最闲的会被驱逐转冷 —— **但正在等人回答的永不驱逐**。

**没有「开热」接口，也不需要。** 你不可能和一个冷对话对话 —— 所以正在被聊的那个话题
按定义就是热的。**发第一条消息就是开热这个动作**，后端自己处理，前端完全不用管。

`POST /conversations/{id}/close` = **转冷不是删除**：关掉进程，消息一条不少。
**话题没有删除接口**，因为它是唯一能回答「这段为什么改成这样」的东西。

### 消息

**只能追加和读取，没有修改和删除** —— 对话是过程记录。

`POST /conversations/{id}/messages`：

```json
{
  "actor_id": "0193...",
  "role": "user",
  "content": "第 3 节和第 1 节矛盾吗？",
  "refs": [
    { "type": "document",   "id": "0193..." },
    { "type": "annotation", "id": "0193...", "document_id": "0193..." },
    { "type": "proposal",   "id": "0193...", "document_id": "0193..." },
    { "type": "project",    "slug": "my-project" },
    { "type": "attachment", "id": "0193..." }
  ]
}
```

- `role` 只能是 `user` | `assistant`
- `content` 存**原始文本**，不要传拼接好的上下文。重放时会按**当前**文档状态重新展开 refs，
  存展开结果等于三周后把旧快照喂回模型
- `position` 由后端分配，单调递增
- **没有 `conversation` 类型。** 展开一条 ref 只渲染它自身，不跟随它的指针 ——
  而对话是唯一做不到这点的形状（它的每条消息又带 refs）。话题之间要传递信息，
  引用的是**结论**（批注）和**提案**，不是聊天流水

响应里每个 ref 有两组信息，**用途不同，别只用一组**：

| 字段 | 用途 |
|---|---|
| `payload` | 客户端原样发来的 ref map，**重放用这个** |
| `ref_type` / `ref_id` | 规范化后的可索引形式，**反查用这个** |
| `position` | refs 的展开顺序 |

两者不能互推：project 用 `slug` 不用 `id`。`ref_id` 可能为 `null`（如 slug 已失效），
这只影响那一条的反查，不影响重放。

列表分页用 `?after_position=N&limit=M`（`limit` 1–200），按 `position` 升序。

---

## 7. Proposals / 争用 / Commit（改动层）

```
GET|POST /documents/{document_id}/proposals
GET      /documents/{document_id}/proposals/{id}
POST     /documents/{document_id}/proposals/{id}/decide
GET      /documents/{document_id}/contentions
GET      /documents/{document_id}/conversations/{conversation_id}/blocks
POST     /documents/{document_id}/commit
```

### 核心概念

两个 revision 之间**没有第二套 blocks**，只有「最新 revision + 挂在上面的提案」。
一篇文档一份工作副本，所有话题共享 —— 所以文档**永远不会分叉**，
分歧被压到 block 粒度，由人做选择而不是文本合并。

### 提案身份 = (block, conversation)

一个话题在一个 block 上**最多一条活跃提案**。同一话题连改五次是**同一个意图在迭代**，
第五次会**就地改写**同一行，不会产生五条。数据库用部分唯一索引强制。

于是冲突判据极简：

```
某 block 上 live 提案数 == 1  →  有改动，无争议
某 block 上 live 提案数 >= 2  →  争用，需要人裁决
```

没有锁、没有版本号、没有先写者优先。

### 提案

`POST /documents/{id}/proposals`：

```json
{
  "block_id": "0193...",
  "conversation_id": "0193...",
  "actor_id": "0193...",
  "content": "改写后的整段正文"
}
```

响应比较特别：

```json
{ "data": { "...proposal..." }, "live_proposals": 2, "contended": true }
```

**`contended` 要立刻反馈给发起的话题** —— 让它知道有人也在动这段，
它可能就不会继续在「我的版本一定会赢」的假设上往下推。这是告知，不是阻塞。

- `block_id` 必须是最新 revision 里存在的 block，否则 `422 unknown_block`
- `status` / `decided_by_actor_id` 传了会被忽略
- **提案只能改已有 block，不能增删块**（当前限制，见 §11）

### 读：每个话题看到的文档

`GET /documents/{id}/conversations/{conversation_id}/blocks`

```json
{ "data": [{
  "block_id": "0193...", "position": 0,
  "content": "这个话题自己的提案内容，没有提案则是已提交的正文",
  "proposal_id": "0193...", "proposed": true,
  "other_proposals": 1
}]}
```

`other_proposals` **只有数量，没有别人的正文** —— 这是刻意的：
调和版本是人的决定，给出计数只是为了让话题知道自己不是唯一在动这段的。

### 争用与裁决

`GET /documents/{id}/contentions` → 活跃提案 ≥ 2 的 block 及其全部竞争提案。

争用**有位置**（在 block 上），所以可以标在文档上，视觉权重与 ❗ 同级。

出口只有两个：

| 出口 | 做法 |
|---|---|
| **选择其一** | `POST /proposals/{id}/decide`，body `{"actor_id": "..."}` |
| **开个话题决定** | 新建话题，把两条提案 + 两个来源话题作为 refs 喂进去 |

**没有「手动融合」。** 想要第三版，去话题里说。

> ⚠️ **裁决 ≠ 提交。** `decide` 只把落选的转 `rejected`，
> **赢家仍是 `live`**，还要走 commit 才落地。
> 所以 `decide` 返回的提案 `status` 是 `"live"`，这不是 bug。

**提案永不删除**，只做状态流转（`live` → `accepted` / `rejected`）。
「为什么选了 A 不选 B」是这套系统最值钱的记录。默认列表会带上已裁决的，
只看还站着的请加 `?status=live`。

### Commit —— 三件事的交汇点

`POST /documents/{id}/commit`：

```json
{
  "actor_id": "0193...",
  "base_revision_id": "0193...",
  "block_ids": ["0193...", "0194..."],
  "resolve_annotation_ids": ["0193..."],
  "source_conversation_id": "0193...",
  "change_summary": "对齐术语"
}
```

**一个事务里同时做三件事**：

1. 用选定提案创建新 revision
2. 把 `resolve_annotation_ids` 里的批注标为 `resolved`，指向本次 revision
3. 被采用的提案转 `accepted`

第 2 条尤其重要：**commit 是批注 resolve 唯一自然的发生地点** ——
只有这一刻，人既做了决定又改了文档。所以提交界面**应该带「本次解决了：批注 1、批注 3」的勾选**。
一次讨论涉及 3 条批注可能只解决 2 条，所以是逐条勾选，不是批量关闭。

其他规则：

- **`block_ids` 省略** = 提交所有「恰好一条活跃提案」的 block，自动跳过争用的
- **逐 block 可取舍**：选中的 block 有未裁决争用 → `409 unresolved_contention`，
  `details.block_ids` 给出是哪些。**但不影响其他 block** —— 去掉它们再提交即可
- 设计建议：**默认全部勾选**，想退回的才动手
- `base_revision_id` 过期 → `409 stale_document`
- 没有任何可提交的 → `422 nothing_to_commit`
- 批注不属于本文档 → `422 annotation_not_found`，**整个事务回滚，什么都不会写**

**不要给「小改动」开自动提交的例外。** 一旦有例外，用户就得开始猜「这次是自动的还是要我审的」，
信任从这里开始崩。正确做法是让 commit 足够便宜。

### 跨文档提交

revision 是 per-document 的，所以一次讨论改 N 篇 = **N 个 revision**，
前端对 N 篇各调一次 `/commit`。**没有跨文档的提交实体** ——
「这次讨论改了什么」靠 `source_conversation_id` 反查，不是存起来的东西。

---

## 8. Attachments（图片）

```
POST   /attachments          # multipart/form-data
GET    /attachments/{id}
GET    /attachments/{id}/content
DELETE /attachments/{id}
```

上传用 `multipart/form-data`，字段 `file` + `actor_id`。**不是 base64 JSON** ——
base64 大三分之一，且必须先解码才能校验。

限制：≤ 4.5 MB、≤ 8000 px（超限分别是 `413 image_too_large` / `422`）。
建议前端先降采样，这是成本问题不只是限制问题。

`GET /{id}/content` 返回原始字节（带正确 `Content-Type`），**给前端渲染用** ——
刷新之后聊天记录里只有 id 没有字节，引用的图仍要显示出来。可直接用作 `<img src>`。

---

## 9. AI Models

`GET /ai_models` → 本机 pi 运行时支持的 provider / model 列表，用于配置 AI actor。

响应除 `data` 外带一个 `status`：`{ state, loading, updated_at, error }`。
**请对 `state` 分支**，`error` 是给运维看的诊断文本。

`POST /ai_models/refresh` 触发重新发现。

---

## 10. WebSocket：实时对话

REST 负责持久化，**实时聊天走 WebSocket**。

- 端点：`/socket`（Phoenix Socket，可用 `phoenix.js`）
- Topic：**`conversation:{conversation_id}`**
- **无认证**（见 §11）

```js
const socket = new Socket("/socket", {})
socket.connect()

// 按话题寻址，不是按 pi 进程
const channel = socket.channel(`conversation:${conversationId}`, {})
channel.join()
```

**按话题寻址而不是按进程寻址**，这带来两件事：

1. **join 不启动任何进程** —— 用户点开只是想读，不该为此开一个 pi
2. **频道比进程活得久** —— pi 挂掉时你收到一条 `exit`，但**频道还在**。
   再发一条消息就会起一个新进程，你不需要重新 join、也不需要去查新的 id

**离开频道不会让话题转冷。** 转冷是显式的 `close` 消息，或 `POST /conversations/{id}/close`。

### 客户端 → 服务端

| 事件 | payload | 说明 |
|---|---|---|
| `prompt` | `{message, refs?, images?, actor_id?, on_missing_refs?, streamingBehavior?}` | 正常对话 |
| `command` | `{type: "get_state", ...}` | 原始 RPC 命令。**需要进程已在跑，不会去启动一个** |
| `answer` | `{ui_id, value \| confirmed \| cancelled}` | 回答 AI 的提问 |
| `pending_ui` | `{}` | 重新拉取待回答的问题 |
| `close` | `{}` | 转冷：关进程，消息一条不少，频道保留 |

`prompt` 的 `refs` 与 §6 消息的 refs 同构。**任何一个 ref 解析失败，整条 prompt 被拒**，
不会「悄悄丢掉引用后照发」—— 半个问题比没有问题更糟，模型会自信地回答一份它根本没看到的文档。

失败分两种，处理方式不同：

| `reason` | 含义 | 前端该做什么 |
|---|---|---|
| `ref_not_found` | 引用的东西**没了**（文档归档、附件删除）。`details.refs` 列出**全部**失效项 | 弹窗列出来问「忽略并发送？」；用户确认后带 `"on_missing_refs": "skip"` 重发 |
| `invalid_ref` | 引用**格式错**（缺 `document_id`、未知 type） | 这是前端 bug，不要提供「忽略」，直接报错 |

`skip` 时失效的引用不会凭空消失，而是渲染成 `<reference status="unavailable">` 标记 ——
否则模型面对「精简这段」却没有「这段」，还完全不知道本该有东西，跟悄悄丢掉没区别。

> **为什么需要这个开关**：失效的引用**可能来自重放的历史消息**，前端删不掉它们。
> 没有这个开关，一个三周前引用过、现已归档的文档会让整个话题**永远打不开**。

带 `actor_id` 时，这条用户消息会**自动落库**；没带就只聊不记录。

第一条消息还会**自动开热**（话题没有 pi 进程时起一个）。可能的失败：

| `reason` | 含义 |
|---|---|
| `assistant_actor_required` | 话题没设 `assistant_actor_id`，不知道该以谁的身份回答 |
| `session_limit_reached` | 所有运行中的会话都卡在等人回答，而这些永不驱逐。提示用户去关一个 |
| `agent_unavailable` | pi 起不来 |
| `not_running` | 只可能来自 `command` / `answer` —— 它们不会去启动进程 |

### 服务端 → 客户端

| 事件 | 说明 |
|---|---|
| `event` | 对话帧：`message_start` / `message_update` / `message_end` / `turn_start` / `turn_end` |
| `ui_request` | AI 在等人回答 |
| `ui_resolved` | `{ui_id}`，该问题已被（可能是另一个标签页）回答 |
| `pending_ui` | join 后立即推送一次，让晚到的客户端也能看到几小时前的提问 |
| `exit` | pi 进程结束。**频道不关**，再发消息即起新进程 |

流式渲染用 `message_update`；**落库只在 `message_end`**（后端自动做，前端不用管）。

### 「等你回答」不能省

pi 的提问**永不超时**。一个话题卡在等人回答，不去点就永远卡着，进程也一直占着。
这是并发设计里**唯一不能省的 UI 元素** —— 必须在话题列表和 tab 角标上体现。

四种提问（`select` / `confirm` / `input` / `editor`）都必须提供**「取消 / 跳过」**，
AI 会把取消当作「用户拒绝回答」并继续往下走。

---

## 11. 已知缺口与限制

按对前端的影响排序：

### 🟢 已修复：话题开热（原阻断性缺口）

早先版本没有任何入口能启动一个绑定到话题的 pi 会话，导致消息自动落库整条链路是死的。
现在**发第一条消息就会自动开热**，重放也由后端在发送时注入。
如果你看到旧文档提到「手动补写消息」或「先调 open 接口」的做法，那都已经不需要了。

### 🟡 其他

| 缺口 | 说明 |
|---|---|
| **无认证** | REST 和 WebSocket 都完全公开。WebSocket 尤其值得优先处理 —— 它能驱动 AI 并替人回答确认框 |
| **无分页** | 所有列表一次返回全部。`messages` 有 `after_position`/`limit`，但没有 `next_cursor`。文档、批注、提案多了会变慢 |
| **提案不能增删块** | 只能改已有 block 的内容。要插入/删除/移动段落，目前只能走 `POST /revisions` |
| **`superseded` 无人产生** | 提案状态枚举里有，但当前没有任何路径会产生它。前端可以先不处理 |
| **重放上限 200 轮** | 安全阀，不是预算 —— 一百轮聊天几千 token，引用的文档还跨轮去重，离上下文窗口差一个数量级。设这么高是因为撑爆窗口是**硬失败**（话题打不开），降级好过报错 |
| **「开个话题决定」需要前端组装** | 后端提供了 `proposal` ref 类型，但没有一键创建裁决话题的接口。前端自己建话题 + 塞 refs |
| **批注快照会过期** | `block_text` / `selected_text` 是创建时的快照，正文改了就对不上。UI 需要能表达「原文已改」 |
| **`messages` 无保留策略** | 永久存储，将来按需加 |
| **落选提案会累积** | 同上，等有量了再定清理策略 |
| **跨文档话题无全局入口** | 话题不属于任何文档，但目前只能从文档侧的批注反查进去 |

---

## 12. 端到端流程参考

```
① 人选中正文 → POST /documents/{id}/annotations          （○ 待办）
② 选中 N 条批注开话题 → POST /conversations
   → 首条消息的 refs 就是这 N 条批注
③ join conversation:{id} → 发消息（自动开热）        （● 讨论中）
   AI 想改文档 → POST /documents/{id}/proposals
   若返回 contended=true → 文档上标出争用
④ 争用裁决 → POST /proposals/{id}/decide                  （赢家仍是 live）
   或新建空话题，把两条提案作为 proposal ref 喂进去（中立，不从任一方 fork）
⑤ AI 写回结论 → POST .../replies（带 source_message_id）  （❗ 待你处理）
⑥ 人审阅 → POST /documents/{id}/commit
   带 resolve_annotation_ids 勾选本次解决的批注
   ↓ 一个事务
   新 revision + 批注转 resolved + 提案转 accepted        （无标记，完成）
⑦ POST /conversations/{id}/close                          （话题转冷，记录永久保留）
```

---

## 附：相关设计文档

想知道「为什么这么设计」，按需读：

| 文档 | 内容 |
|---|---|
| `docs/document-annotations.md` | 批注 = 结论，status 生命周期 |
| `docs/document-conversations.md` | 对话 = 过程，多话题并发、冷热会话 |
| `docs/document-working-session.md` | 改动 = 提案 → commit，争用与裁决 |
| `docs/ui-document-workspace.md` | 前端完整规格（布局、四档标记、交互） |
| `docs/ui-document-workspace-edge-cases.md` | 边界情况 |
| `openapi.yaml` | 字段级契约，以此为准 |
