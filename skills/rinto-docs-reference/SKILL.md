---
name: rinto-docs-reference
description: 领取并执行 Rinto 项目任务，按任务关联的方案、规范和设计决策完成开发，并把开始、完成或释放状态同步回 Rinto。当用户要求处理 Rinto 任务、任务描述点名 Rinto 文档、或需要确认项目既有约定时使用。
---

# 执行 Rinto 任务与查阅项目文档

Rinto 里的 Task 是要交付的工作，Document 是这项工作的决策依据。
开发端 agent 要形成一个闭环：**找任务 → 领取 → 读任务和文档 → 开始 → 实现与验证 → 完成**。
不要只在本地做完代码而让 Rinto 里的任务一直停在旧状态。

## 前提

CLI 首次使用时需要配置 API 和 token：

```sh
rinto-pmo config init --api http://localhost:4000/api/v1 --token <TOKEN>
```

token 由服务端管理员执行 `mix rinto.actors.setup_human` 打印出来，**每个请求都要带它**，
没有它服务端一条接口都不会回应。`config init` 会用这个 token 反查 `/actors/me`
确认它有效，然后把 API 地址、token 和用户 id 写进 CLI 配置文件（权限 0600）。

后续命令自动读取，不要手工拼 actor id，也不要把远程 AI actor 当成本地执行者。
可以用 `rinto-pmo config show` 检查当前配置 —— 它只会显示 token 是否配好，不会打印 token 本身。

## 1. 找到项目和任务

不知道 project slug 时，先发现项目并确认它关联的代码仓库：

```sh
rinto-pmo project list
rinto-pmo project show <project-slug>
```

`project show` 返回项目描述以及仓库 URL、目录名和默认分支。确认当前工作区对应任务所属的仓库，
不要因为本地恰好打开了另一个仓库就在错误的位置实现。

查看项目里无人领取且尚未结束的实际工作：

```sh
rinto-pmo task list <project-slug> --kind work --assignee-id none --live true
```

恢复工作时，先看当前 actor 已领取的任务：

```sh
rinto-pmo task list <project-slug> --kind work --mine --live true
```

列表按创建时间从旧到新。`summary` 是工作分解的汇总节点，不是可以领取和执行的工作，
所以开发任务池必须带 `--kind work`。

如果用户已经给了 task id，不必先列项目，直接读取：

```sh
rinto-pmo task show <task-id>
```

## 2. 先领取，再动手

```sh
rinto-pmo task claim <task-id>
rinto-pmo task show <task-id>
```

`claim` 不需要指定领取人 —— 服务端从 token 认出你是谁，并且是并发安全的。
如果返回 `task_already_claimed`，说明别人先拿到了：**不要重试抢同一个任务**，重新列任务池并选别的任务。

领取成功后重新 `show`，确认这些信息：

- `title` 和 `description`：交付目标与约束
- `document_id`：实现依据
- `parent_id`：它在工作分解中的位置
- `due_on`、`estimate`：期限和估算
- `assignee_id`：确实是当前 actor

## 3. 读取实现依据

如果任务的 `document_id` 不是 `none`：

```sh
rinto-pmo doc show <document-id>
```

Rinto 文档是项目的**决策记录**：方案、规范、已经拍板的设计。
实现前先读，不要凭个人习惯覆盖已有约定。

不确定还有没有相关文档时，可以用 `task show` 返回的 `project_id` 列出项目文档：

```sh
rinto-pmo doc list --project-id <project-id>
```

如果实现过程中发现文档方案有问题，先向用户说明冲突和理由，不要自行偏离。
文档中的「明确不做」尤其需要遵守。

## 4. 开始、实现、验证

只有在已经领取且准备实际动手时才开始任务：

```sh
rinto-pmo task start <task-id>
```

然后按任务和关联文档实现。遵守客户代码库自己的 `AGENTS.md`、测试和提交规范；
Rinto 的任务描述不会替代仓库约定。

完成状态意味着交付已经达到任务要求，不只是“代码写了一半”。在回报完成前：

1. 检查任务描述中的每个要求；
2. 运行客户仓库要求的测试、格式化和静态检查；
3. 查看最终 diff，确认没有无关改动。

## 5. 回报结果

验证通过后：

```sh
rinto-pmo task complete <task-id>
```

如果确认无法继续、需要让别人接手，释放所有权：

```sh
rinto-pmo task release <task-id>
```

`release` 不是取消任务；工作仍然存在，而且已经开始的状态和时间会保留。
不要因为暂时遇到困难就 `cancel`。取消表示团队决定不再做这项工作，应由明确的项目决策触发。

## 状态纪律

- 不要处理未领取的任务。
- 不要对 `summary` 节点执行 claim/start/complete。
- `open → start → in_progress → complete → done` 是正常路径。
- claim 冲突后换任务，不自动重试。
- 本地实现或测试失败时不要 complete。
- 需要交接时 release，并向用户说明剩余问题。
- 不要用 delete 代替 cancel；delete 只适合本不该存在的误建记录。

## 命令权威

本文描述工作流，不复制所有管理命令和 JSON 写入格式。
当前二进制支持的参数以这些帮助为准：

```sh
rinto-pmo project --help
rinto-pmo task --help
rinto-pmo task <command> --help
rinto-pmo doc --help
```

这个 skill 只指导客户开发端执行任务和读取文档。创建、修改 Rinto 决策文档仍是服务端 agent 的职责，
不应在客户代码仓库里擅自改写。
