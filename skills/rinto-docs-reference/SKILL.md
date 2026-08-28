---
name: rinto-docs-reference
description: 领取并执行 Rinto 项目任务，按任务关联的方案、规范和设计决策完成开发，并把开始、完成或释放状态同步回 Rinto。当用户要求处理 Rinto 任务、任务描述点名 Rinto 文档、需要按意思搜索项目里的内容、或需要确认项目既有约定时使用。
---

# 执行 Rinto 任务与查阅项目文档

Rinto 里的 Task 是要交付的工作，Document 是这项工作的决策依据。
开发端 agent 要形成一个闭环：**找任务 → 领取 → 读任务和文档 → 开始 → 实现与验证 → 完成**。
不要只在本地做完代码而让 Rinto 里的任务一直停在旧状态。

## 前提

CLI 首次使用时需要配置 API 和 token：

```sh
rinto-pmo config init
```

它会一步步问 API 地址和 token（输入 token 时不回显）。API 地址直接回车即可 ——
默认就是 `https://pmo-api.kenton.wang/api/v1`，只有指向本地服务时才需要覆盖。
token 是**提前约定好的值** —— 服务端启动时以 `RINTO_TOKEN` 拿到的那一个，
向部署它的人要。**每个请求都要带它**，
没有它服务端一条接口都不会回应。`config init` 会用这个 token 反查 `/actors/me`
确认它有效，然后把 API 地址、token 和用户 id 写进 CLI 配置文件（权限 0600）。

非交互场景（脚本、CI）仍可以用 `--api` 和 `--token` 直接传。

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

**不带 project slug 就是跨项目的整个任务池**，容量本来就是跨项目共享的：

```sh
rinto-pmo task list --kind work --assignee-id none --live true --sort plan
```

`--sort plan` 是排期板自己的顺序（优先级 → 排到的那天 → 建的时间），
所以第一行就是计划下一步会做的那条。不加就是从旧到新。

恢复工作时，先看当前 actor 已领取的任务：

```sh
rinto-pmo task list <project-slug> --kind work --mine --live true
```

`summary` 是工作分解的汇总节点，不是可以领取和执行的工作，
所以开发任务池必须带 `--kind work`。

### 这条活在不在计划里

```sh
rinto-pmo schedule                          # 本周
rinto-pmo schedule --from 2026-09-07 --to 2026-09-21
```

每周打出装进容量的任务、`overflow`（选进了这周但没装下）和 `blocked`
（在等一条没装下的前置）。**一条任务如果压根不在这张表里，说明它没被排进任何一周**
——那是 backlog，做它是「在计划之外干活」，不是推进计划。

真要找 backlog 里最该捞的一条：

```sh
rinto-pmo task list --kind work --live true --scheduled false --sort plan
```

用户明确指名的任务照做，不必先查计划；上面这些是**自己挑活**时用的。

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
- `priority`、`planned_start_on`：它在计划里的位置。
  `planned_start_on: none (backlog)` 表示这条活不在任何一周里——**你正在计划之外干活**，
  这本身不一定错（用户点名的活照做），但要知道自己在做什么
- `difficulty`：Fibonacci 故事点，是对工作的评级，不是工时；工时看 `estimate`

`start` / `complete` / `release` 现在由服务端强制这一条：不是持有人就返回
`403 task_not_yours`，`details.assignee_id` 会告诉你它属于谁。
这和 `task_already_claimed` 不同——那个是抢输了，换一条任务就行；`403` 表示这条活
根本不归你，重试没有意义，要么去任务池领一条，要么是 task id 拿错了。

## 3. 读取实现依据

如果任务的 `document_id` 不是 `none`：

```sh
rinto-pmo doc show <document-id>
```

Rinto 文档是项目的**决策记录**：方案、规范、已经拍板的设计。
实现前先读，不要凭个人习惯覆盖已有约定。

### 这份规范上有没有还没解决的异议

正文之外，文档上可能挂着**批注**（annotation）—— 有人指着某一段说这里不对。
`doc show` 看不到它们，要单独问：

```sh
rinto-pmo doc annotations <document-id> --status open
```

一行一条，包括它挂在哪个 block 上。**一条 open 的批注意味着那一段正在被质疑，
还没有人拍板。** 你要实现的正好是那一段时，先读完整一条：

```sh
rinto-pmo doc annotation <document-id> <annotation-id>
```

追评里标着 `a conclusion from topic message …` 的，是讨论得出的结论。

**照正文实现，然后把冲突说出来。** 批注不是新的规范，正文才是；
但正文的这一段正被质疑而你照做了，值得在回报时说一句。
不要自己按批注里的说法去改实现，也不要去动批注的状态 —— 那是人的动作。

不确定还有没有相关文档时，有两条路：

**按意思找** —— 不知道叫什么、只知道要找什么内容时用这个：

```sh
rinto-pmo search "部署回滚怎么做" --type block --project-id <project-id>
```

它按语义召回，返回的每行**以完整地址开头**，命中的是**具体某一节**而不是整篇文档
（`--type document` 则返回文档）。地址可以直接拿去 `doc show`（见下）。

**按项目列** —— 想看全量、或者只是要个清单时用这个：

```sh
rinto-pmo doc list --project-id <project-id>
```

搜索只覆盖已建立索引的内容，**刚写完的东西可能要过几秒才搜得到**；
列表是实时的。两者互补，不要只用一个。

### 正文里遇到 `rinto://` 链接

文档正文里会出现这样的链接：

```markdown
先做 [接入 r-nacos](rinto://task/01936f2a-…)，细节见 [部署一节](rinto://block/01a023d8-…)
```

**地址本身就说明了该跑哪条命令**，按类型对应：

| 地址 | 跟进方式 |
|---|---|
| `rinto://document/{id}` | `rinto-pmo doc show {id}` |
| `rinto://block/{id}` | `rinto-pmo doc show` 它所属的文档，找到那一节 |
| `rinto://task/{id}` | `rinto-pmo task show {id}` |
| `rinto://project/{slug}` | `rinto-pmo project show {slug}` |

**这些链接是实现依据的一部分，不是装饰。** 任务描述或文档里指向另一份文档的某一节，
通常意味着那一节就是这件事的约定所在 —— 跟进去读，不要跳过。

链接失效（指向已删除的东西）是可能的：这时按链接文字判断它原本想说什么，
必要时向用户确认，不要自行推断出一个替代目标。

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
rinto-pmo task complete <task-id> --actual-minutes 90
```

第二种写法一并记下这条活实际花了多少分钟。**知道就写，不知道就用第一种**——
不写是「保持原样」，不是清空，人后面可以补。这个数字是估算之外唯一被系统消费的
产出：后续估算拿它校准。别拿它当工时报表，也别为了凑一个数去猜。

如果确认无法继续、需要让别人接手，释放所有权：

```sh
rinto-pmo task release <task-id>
```

`release` 不是取消任务；工作仍然存在，而且已经开始的状态和时间会保留。
不要因为暂时遇到困难就 `cancel`。取消表示团队决定不再做这项工作，应由明确的项目决策触发。

注意：`release` 之后这条任务就没有持有人了。如果后来又想把它做完，必须先重新
`claim` —— 服务端不接受完成一条无人持有的任务。

## 状态纪律

- 不要处理未领取的任务。
- 不要对 `summary` 节点执行 claim/start/complete。
- `open → start → in_progress → complete → done` 是正常路径。
- claim 冲突后换任务，不自动重试。
- 收到 `403 task_not_yours` 不要重试，也不要试图绕过：换一条自己领的任务。
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
rinto-pmo schedule --help
rinto-pmo doc --help
rinto-pmo search --help
```

这个 skill 只指导客户开发端执行任务和读取文档。创建、修改 Rinto 决策文档仍是服务端 agent 的职责，
不应在客户代码仓库里擅自改写。
