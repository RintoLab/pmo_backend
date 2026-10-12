---
name: rinto-requirements
description: 在 Rinto 中查看、创建和完善需求草稿，按用户要求拆分子需求，或查找需求下的规格、实施计划和任务清单文档时使用。处理 Requirement 资源及其文档归属，不负责领取或执行开发任务。
---

# 在 Rinto 中完善需求

Requirement 是需求资源；它的 description 承载背景、目标和验收描述，不另建一份同内容的 PRD。Project 表示业务系统，Repo 表示代码仓库。需求属于一个 Project，可以逐层拆成同一 Project 下的子需求。

需要从需求生成 spec、澄清、生成 plan 或 task 时，使用 `rinto-spec-workflow` 技能。
该流程通过本技能的命令保存资源，不要求用户预先提供 PRD，也不自行采纳文档。

## 找到需求及其上下文

话题进程已经提供 API、token 和 conversation 环境，直接使用 `rinto-pmo`，不运行 `config init`。创建顶层需求时需要的 Project slug 从列表读取；已有需求通过 ID 定位。

```sh
rinto-pmo requirement list
rinto-pmo requirement list --project <slug>
rinto-pmo requirement list --parent-id <requirement-id>
rinto-pmo requirement list --project <slug> --parent-id all
rinto-pmo requirement show <requirement-id>
```

列表默认只显示未归档的顶层需求；指定父需求后只列直接子需求。详情包含所属项目、父需求、状态、归档时间、子需求数量、完整描述、Task 估时汇总和直接关联的未归档文档摘要。总览也包含已归档项目的需求，供追溯查看。

修改前先读详情；完善子需求时也读父需求，保留父需求中明确的范围和限制。

在文档或说明中引用需求时，写成 `[需求标题](rinto://requirement/{id})`，id 必须来自
上述 list/show 或 create 返回值。读到这种链接时用 `rinto-pmo requirement show <id>`
跟进。引用需求的 spec/plan/task 文档则使用 `[文档标题](rinto://document/{id})`；
链接不代替文档归属字段 `--requirement-id`。

## 创建与修改草稿

把描述写入 UTF-8 Markdown 文件，通过 `--body` 传入。标题单独传给 `--title`。

```sh
rinto-pmo requirement create --project <slug> --title "账号体系升级" --body requirement.md
rinto-pmo requirement create --parent-id <parent-id> --title "短信登录" --body child.md
rinto-pmo requirement update <requirement-id> --body requirement.md
rinto-pmo requirement update <requirement-id> --title "新标题"
rinto-pmo requirement update <requirement-id> --priority 1
```

创建时 `--project` 和 `--parent-id` 二选一；子需求自动继承父需求的 Project。`update --body` 替换完整描述，写文件时保留用户未要求删除的内容。省略字段保留原值，传空文件清空描述。标题和描述只允许修改未归档项目中的未归档草稿；优先级在 draft、analyzed 和 active 状态均可调整。Project 和父需求不能通过编辑改写；进度状态可用 `--status` 单独标记，见下文。

优先级保存在 Requirement，取值 1–5（1 最高，默认 3），创建时也可传 `--priority`。任务实时继承所属需求的优先级，不能通过 task create/update 单独赋值。任务创建必须提供同一 Project 下未归档、开放的叶子需求 `requirement_id`；已有任务的需求不能再添加子需求。任务没有独立的父子层级，按所属需求组织。

按用户要求的交付粒度创建子需求，每个子需求写清自己的目标、范围和验收结果。创建成功后记录返回的 ID；发生错误或中断后先列出已有子需求，避免重复创建。拆分需求不等于创建开发任务，也不表示已经完成规格、计划或任务清单。

叶子需求也可按能独立运行、验收和部署的场景分批交付，不必为每批新建子需求。
仍保留 spec → plan → task；批次范围、必要依赖与验收按 rinto-spec-workflow 记录在文档中，
不是新的系统层级或状态。保留剩余范围，部分交付不能标记整个需求完成。
只有用户要求独立管理目标时才拆子需求；已有任务的叶子需求不能直接改成父需求，不绕过此限制。

## 需求文档

```sh
rinto-pmo requirement show <requirement-id>
rinto-pmo doc list --requirement-id <requirement-id> --kind spec
rinto-pmo doc show <document-id>
rinto-pmo doc create --title "短信登录规格" --body spec.md --kind spec --requirement-id <requirement-id>
```

从需求详情的 documents 摘要中取文档 ID，再用 `doc show` 读取正文。文档的列表、读取、创建、分类和修改均使用 `doc` 子命令；没有 `requirement documents` 命令。详情不合并父需求或子需求的文档，需要继承的约束应显式读取父需求及其文档。同一类型可以有多篇文档，应根据标题和内容选择，不默认取第一篇或另建一篇。

`kind` 可用 `general`、`rfc`、`spec`、`plan`、`task`；任务清单的类型是 `task`，导出文件仍可命名 `tasks.md`。文档创建时带上 `requirement_id`，服务端据此确定 Project。普通文档库不展示已关联需求的文档，需求文档从需求入口查看。

已有文档的正文修改沿用 `rinto-document-authoring` 技能的提案与人工审阅流程。需求描述的编辑命令不能用于绕过文档审阅。用户要求的某份文档已经存在时，先读取再修改，避免另建重复文档。

## 按需求批量估时

```sh
rinto-pmo requirement estimate <requirement-id> <another-id> --wait
rinto-pmo requirement show <requirement-id>
```

按用户要求启动，使用已配置的 `task_estimation` AI 角色。仅补齐未完成且没有估时的 Task，不覆盖已有值。选择父需求自动展开开放的叶子需求，重叠选择去重；没有 Task 的叶子需求返回待拆解，不能另写一个需求粗估代替。

汇总包含所有后代需求的 Task，每个任务只计入一次。总计保留已结束任务和已归档后代的历史估时；剩余仅统计 open/in_progress。未估时任务和未拆解叶子需求分别计数，null 表示未知，不能当作零。工时不等于交付日期。

估时使用需求及其祖先的描述、未归档 spec/plan/task 文档和同 Project 历史。每批最多 20 个任务；期间人工修改或文档变化会拒绝过期结果。失败时先查看原因和最新汇总，之前成功的批次会保留；不要自动反复调用模型。

## AI 判断优先级

```sh
rinto-pmo requirement prioritize <requirement-id> --wait
rinto-pmo requirement update <requirement-id> --priority 2
```

使用 `requirement_prioritization` AI 角色，根据当前需求及其上下文直接更新该需求的优先级（1 最高、5 最低）。不比较其他需求，不展开子需求，也没有审阅或应用步骤。Task 自动继承各自所属需求的优先级；用户认为不合适时直接手动修改。

`--wait` 等待后台作业结束并显示需求。排队或执行期间有人修改需求时，保留手动修改，不用旧结果覆盖；相关描述或文档变化也会停止写入。失败时查看原因，不自动反复调用模型。

## Task repository ownership

Each task must specify one `repo_id` from the requirement's Project, alongside
`requirement_id` and `title` in `task create` input. Get the project's registered
repositories before choosing; never invent or guess a Repo ID. Cross-repository
work becomes separate tasks with their own Repo IDs and dependencies. Split
children inherit the original Repo unless they explicitly choose another Repo
in the same Project. Filter execution work with `task list --repo-id <ID>`.
The legacy document breakdown importer can infer a Repo only when the Project
has exactly one registered repository; it refuses ambiguous ownership.

## 从 task 文档同步任务

先 `doc show` 读取完整正文和 revision id，再 `task schema sync` 读取结构化格式。
调用 `task sync <document-id> --input <JSON-file>`；只需文档 ID，不再传 Project
或 Requirement。文档必须是已采纳的 `kind=task`，并归属于开放的叶子需求。
草稿须由用户在网页采纳，不能通过同步接口替代采纳。

输入为 `base_revision_id` 加 `tasks` 数组，每项含稳定的 `key`、`title`、
`repo_id` 和可选 `description`。编号取自正文，例如 T001；仓库名称必须映射到
实际登记的 Repo。系统不解析 Markdown，不从复选框设置执行状态，不自动推断依赖。
生成任务文档时就提供稳定编号；旧文档没有编号时先提案补齐，采纳后再同步。

同一文档的编号标识同一个任务，重复提交不会重复创建。新版本仅更新没有人工冲突的
未开始任务的标题、说明和 Repo。估时、负责人、排期、状态和依赖不会被覆盖。
遗漏条目不会删任务，已删除任务不会被重建。同一版本对既有编号给出不同内容也会拒绝。
冲突时整个批次不写入，报告具体编号；不要通过换编号、换文档或 task update 绕过。
遇到 stale_document 必须重读正文，不能只获取新 revision id 重试。

## 需求进度标记

`requirement update <id> --status draft|analyzed|active|completed` 可手动标记或改回状态，父需求同样适用。
`analyzed` 表示文档与规划已就绪、等待实现，尚未进入 active；由用户要求时手动标记，不代表系统已验证文档或保存一致性检查审批。
状态切换不检查文档或任务完成情况，也不批量改变 Task。第一个 Task 成功开始时，仅将未归档的 draft 或 analyzed 需求自动标为 active；任务全部完成不会自动完成需求。
