# Document Annotations

状态：**已实现**（单层追评，无 reply-to-reply）。
`status` / `resolved_by_revision_id` / `source_message_id` 已实现。

与设计的两处差异，均为实现时补的洞：
- `dismissed` 也清空 `resolved_by_revision_id`（原设计只写了 reopen 要清）。
  dismissed 表示未改文档，留着指针即声称一次不存在的修改
- 「有结论待处理」判定为 `status == :open` 且存在 `source_message_id` 非空的追评，
  **不含**「晚于最后一次查看」—— 系统无已读状态，且本文档「标记的存亡由 status 决定」
  一节否决了按已读清除

## 已拍板

- 挂 `document_id`，不挂 revision；revision 升级不丢批注
- **有 status**：`open | resolved | dismissed`
  - 原先拍的是「无 status（不是 review）」，已推翻：没有它，「AI 聊完了、该我干预」
    这个状态在系统里无法表达，协同审阅也无从收敛
  - `resolved_by_revision_id?` 指向解决它的那次修改
  - 只有人做出决定才改 status；「被聊过」不改变它
- 追评承载**结论**，不承载聊天流水；过程见 `docs/document-conversations.md`
  - 人和 AI actor 都可以发追评（`Actors.Actor` 的 `kind` 本就统一了两者）
  - 来自对话的结论用 `source_message_id?` 指回出处
- 首条意见：`annotations.content`
- 另存：`block_id?`、`block_text?`（block 文本快照）、`selected_text?`（选中文本快照，无位置）
- `block_id` / `block_text` / `selected_text` 均可选，互不强制
- 无 `base_revision_id`（第一期不要）
- 追评独立表 + 单调 `position`（删不重排）
- 追评可改、可删
- 列表 API 不带追评；详情带全量追评（按 position）

## Schema

### annotations

- document_id, actor_id, content
- block_id?, block_text?, selected_text?
- status（`open | resolved | dismissed`，默认 `open`）
- resolved_by_revision_id?
- timestamps

### annotation_replies

- annotation_id, actor_id, content, position
- source_message_id?（结论出自哪条对话消息）
- timestamps（或仅 inserted_at）
- unique (annotation_id, position)
- 追加 position = max+1；删除不重排
