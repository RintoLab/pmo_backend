# AI 写文档：CLI + Skill（未实现）

状态：机制已拍板，未实现。
相关：`docs/document-working-session.md`（改动的落点）、
`docs/document-conversations.md`（过程）、`docs/document-annotations.md`（结论）。

那三份定的是**改动落在哪里**；本文档定的是**AI 用什么通道把改动送进去**。
它是通道层，不重新定义任何一条已拍板的语义。

## 问题

AI 现在能读不能写。

读已经通了：`Agent.PromptBuilder` 把 `document` / `annotation` / `project` / `attachment`
四类 ref 展开成 prelude 拼进 prompt。反方向没有出口 —— 模型说完「我改好了」，
改动只存在于它那段输出文本里，没有任何东西能把它送进 `documents`。

通道有三个候选：MCP、CLI + skill、pi extension。

## 已拍板：CLI + skill，不走 MCP

**否决 MCP 的理由是它在 pi 上不是原生能力。**
`--mcp-config` 由第三方 extension `pi-mcp-adapter` 提供（`pi --help` 里它列在
"Extension CLI Flags" 下，不在主选项里）。为了一个工具通道去绑一个第三方 extension，
等于把整条写入路径押在别人的发布节奏上。

**否决 pi extension 的理由是它把通道绑死在 pi 上。**
写 JS extension 确实最原生，还能复用 `PiSession` 已有的 parking 机制做写前确认，
但客户端场景里开发者用什么 agent 不由我们决定（见下节），extension 那条路只服务得了服务端一半。

选 CLI 换来的东西不只是「不绑第三方」，还有一条实质优势：

> **共享参考资料可以按需拉取，不必常驻提示词。**

MCP 的 tool schema 是常驻上下文的；CLI 的 `--help` / `schema` 子命令是模型要用才去取的。
下面「一个 CLI 两套 skill」能成立，靠的正是这一点。

## 一个 CLI，两套 skill

有两个使用场景，能力部分重叠：

| | 服务端 | 客户端 |
|---|---|---|
| 谁在跑 | backend spawn 的 `pi`（per-conversation） | 开发者本地的 agent |
| 干什么 | 在话题里读文档、写文档 | 领任务、读文档、实现、回报状态 |
| agent 是谁 | 一定是 pi | 不确定（pi / Claude Code / 别的） |
| 分发 | 烤进镜像 | brew / cargo / curl 脚本 |

### CLI 只做一个

重叠的不是「几个命令」，是整个下半截 —— base URL 解析、HTTP、错误转人话、输出格式、
从 `openapi.yaml` 生成的类型。拆两个二进制就是把这些维护两遍，而区分度只在最上层的名词。
`rinto-pmo doc …` 和 `rinto-pmo task …` 已经把它们分干净了。

**尤其不要用拆二进制去限制能力。**「服务端不该能领任务」是授权问题，
检查得在服务端；靠「没发这个子命令」来约束等于服务端根本没有检查，
而这个二进制早晚要给人手动装，约束不住。

### skill 做两套

skill 的成本是**上下文和注意力**。服务端那个 pi 永远不会去领任务，
让它带着「领取 → 实现 → 回报」的流程说明是纯噪音，还多一份它尝试不适用操作的概率。
反过来客户端也不需要知道服务端产出文档的时机规范。

两者天然落在不同地方：服务端在镜像里的 `~/.pi/agent/skills/`（pi 自动发现该目录，
不需要 `--skill` 参数），客户端在开发者自己机器上。客户端那套还不能写 pi 特有的东西。

### 重叠部分不复制

两边都要的参考**不在两套 skill 里各抄一份** —— 必然漂。
落点是 CLI 按需输出的东西（`--help`，以及将来真需要时的 schema 子命令），
skill 只写一句「看那个命令」。

于是 skill 里只剩各自的工作流：服务端讲「什么时候该产出文档、怎么组织」，
客户端讲「领取 → 读文档 → 实现 → 回报」这个循环。CLI 长到二十个命令，skill 还是那几段。

**第一阶段这条原则没有触发条件**：模型只写 markdown，唯一的结构规则是「`##` / `###` 分节」，
一句话就说完了，两边没有需要共享的 block 结构参考。
原则记在这里是因为第二阶段会用上（见下），不是因为现在需要。

## 第一阶段：只做新建文档

命令面：`doc create` / `doc show` / `doc list`，外加 `skill list` / `skill install`（见「部署」）。

### 标题与正文分开传

`--title` 是标题的**唯一来源**。CLI 不从正文里推断标题。

正文里的一级标题因此就是普通内容 —— 一篇 markdown 允许有多个一级标题，
它们是结构，不是"这篇文档叫什么"。两者是不同的东西，不该互相猜。

曾经走过一段弯路，记下来免得再走：先是让 CLI 把开头的 `# xxx` 当标题剥离，
后来又改成遇到开头 H1 就报错。两个都错在**同一个地方** —— 
把「正文里出现一级标题」当成了要处理的异常，而它根本不是异常。
正确的做法是 CLI 只管从 `--title` 拿标题，正文里有什么标题都当内容。

`doc create --dry-run` 只报告正文会被切成哪些 block，不创建任何东西、也不要求配置环境。
它存在是因为**分块粒度是作者的决定，而作者原本无从检查** ——
没有预览就只能真建一篇再回头收拾。

### CLI 不暴露 revision 概念

`doc create` 的心智就是「建一篇文档」：传 title + blocks。
**初始 revision 由 backend 在建文档时自动产生**，不是 AI 要理解或操作的东西。

revision 只在第二阶段的 commit 语境里对**人**出现。让 AI 去理解「文档有不可变版本历史」
除了增加它出错的花样，没有任何好处 —— 它该关心的是内容。

### 为什么改已有文档不在第一阶段

因为改已有文档必须走 `block_proposals` 提案模型（`document-working-session.md`），
而 working session / `block_proposals` / `conversations` 三层**全部未实现**。

绕过它直接 `POST /documents/{id}/revisions` 是可行的，但那正是 working-session 要解决的问题：
AI 的中间改动会每次生成 revision，把历史污染成一堆没人认可过的检查点。
现在图快省下的，回头要连着数据一起清。

**新建文档则不冲突**：没有 base、没有并发话题、不涉及提案与争用。
它是这套设计里唯一一块可以先行、且不会欠债的部分。

### 认下的缺口

新建文档没有 commit 闸门 —— AI 直接产出一篇文档，没有「人审」这一步。
这与贯穿性不变量「AI 写，人审、人选、人提交」之间留了个口子。

第一阶段接受它，理由是新建文档的破坏面有限（不覆盖任何已有内容，不满意删掉即可）。
等 working session 实现后收拢。**这是已知欠债，不是设计。**

## CLI 设计原则

### 哑管子

block 内容用 `serde_json::Value` 原样透传，Rust 侧**不做结构校验**，服务端 422 就转述。
`Documents.BlockOps` 已经是权威校验，抄一份到 Rust 里只会得到两份会漂的实现，
而且每次改 block schema 都要重发 CLI。

### 正文走 markdown 文件，不走 argv，也不走 JSON

模型先用自己的 write 工具写 `doc.md`，再 `rinto-pmo doc create --title "…" --body doc.md`，
**CLI 按 `##` / `###` 切成 block**（见下节）。

两件事都要避开：

- **不走 argv**：命令行里拼带中文、引号、换行的长文本迟早出事，
  而且失败是静默的 —— 内容被 shell 吃掉一半，命令还是成功退出
- **不走 JSON**：`openapi.yaml` 的 `blocks` 是 JSON 数组，但让模型把整段 markdown
  转义进 JSON 字符串是它出错率最高的操作之一（换行、引号、反斜杠）。
  block content 本来就被定义成一个完整的 markdown 片段 —— 让模型写它最擅长的
  markdown、由 CLI 做那次机械切分，比让它手工转义可靠得多

这一条是对「哑管子」原则的**有意例外**：切分是格式适配，不是业务校验，
`BlockOps` 的权威性没有被分走。JSON 数组形式保留为 `--blocks` escape hatch。

### 切到三级标题，不只是二级

`openapi.yaml` 把 block content 描述成「normally beginning with an H2 heading」，
但只按 `##` 切出来的块**太大**了：拿本文档自己试跑，最大一块 1736 字符。

而 `document-working-session.md:257-263` 明确写着争用方案**依赖 block 粒度接近段落** ——
块一大，两个话题改同一块就从罕见变成常态，而且大多是假冲突（改的是不同句子），
争用界面会退化成骚扰。真实文档一个 `##` 底下通常挂着好几个 `###`，
所以按 `##` 切必然偏离那个前提。

`#` 也切。标题既然只来自 `--title`，正文里的一级标题就是普通结构，
一篇正文可以有好几个。让最浅的那一级**不**切，会把第二个 `#` 粘进它前面那块 ——
不一致的是"唯独 H1 不切"，不是切本身。

`####` 及更深不切：过了三级，片段就不再是能被独立评审的东西了。

这个取舍现在改很便宜，等 `block_proposals` 建起来、库里有了按旧粒度切的数据再改就贵了。

### 输出瘦

成功打一行（`created 0193…`），失败走 stderr + 非零退出码 + 一句人话。
不吐 JSON blob —— 选 CLI 图的就是省上下文，别在输出上还回去。

### 冲突不吞

409 / 422 一律**如实转述**给调用方。CLI 自己不重试、不改写、不兜底。

这条要和 `document-working-session.md:94` 的「明确否决 AI 自动重试」对齐着读，
被否决的是**静默、自动**的那种 —— AI 在一个 turn 内部自行重读新文本、
糅出一个两个话题都没要求过的第三版，而这个决策没有任何人审过。

409 机制本身是保留的（同文档 `:239`：commit 时「若 latest 已变，沿用现有 stale revision 冲突」）。
区别在于**决策发生在哪里**：藏在一个 CLI 进程内部不行，
浮到模型可见处、由它显式做出并留在对话记录里，才是可审的。

### 教材从服务端取，用法烤进二进制

这个 CLI 不只是接口，**它还是模型的教材**。普通 CLI 没这个问题，因为没人从 `--help` 里
学怎么构造数据。

所以凡是模型要照着构造数据的东西从服务端拉；
否则旧版二进制会用**过时的词汇教模型** —— 模型信心十足地拼出服务端已经不认的结构，
然后吃 422，而它没法自己发现，只能试错。

`--help` 那种 clap 生成的用法说明烤进去无妨：旧版本不知道有新命令，那是「不够新」，无害。

一句话：**模型照着构造数据的，服务端取；命令用法，烤进去。**

### 但第一阶段不落地这条

原先据此设计了一个 `doc schema` 子命令 + 对应端点，**已删除**。

理由：那个设计的前提是模型要自己拼 block JSON。改成 `--body doc.md` 之后，
**模型不再构造任何结构化数据** —— block 长什么样、有哪些字段、`actor_id` 怎么填，
全在 CLI 里，模型一概不需要知道。教材没有学生。

真正需要它的是第二阶段：模型要表达「改第 3 块」「在这块后面插一段」时才重新需要词汇。
但那时的形态大概率是提案（`block_proposals`）而非现在的 `block_ops`，结构尚未确定。
**为形态未知的未来需求预留一个当下无用的端点，是过早抽象。**

原则留着，实现等到有触发条件再做。

### 选型

Rust + clap(derive) + `ureq`（阻塞式，不拉 tokio —— CLI 不需要 async runtime）。
放 umbrella 仓库的 `cli/` 目录，就是个 cargo 工程，不是 Elixir app。同仓保证版本不漂、CI 只有一处。

选 Rust 而非 escript：agent 一轮可能调用多次，启动时间是真实收益，
且静态二进制不用往镜像里塞运行时。放弃的是「与 `BlockOps` 共享一份校验实现」，
但上面「哑管子」已经决定不在客户端校验，所以没有实际损失。

## 身份：`actor_id` 与 `conversation_id`

**这不是零 backend 改动的方案**，`openapi.yaml` 的 `DocumentBlockCreateInput`
要求每个 block 带 `actor_id`，而 `Actors.Actor` 的 AI actor 携带
provider / model / system_prompt —— 一个 actor 就是一套 agent 人格，因此是 per-session 的。

| id | 从哪来 | 第一阶段 |
|---|---|---|
| `document_id` / `project_id` | 模型从 prompt prelude 读，当参数传 | 够用 |
| `actor_id` | 会话身份，prelude 里没有 | **CLI 从 env 填，模型不经手**；单 actor 可用部署级 env，多 actor 必须注入 |
| `conversation_id` | 会话身份，`conversations` 未实现 | 记不了来源，认下 |

接线点只有一处：`Agent.PiSession` 的 `init/1` 目前不传 `:env`，
而 `OSProcess` 的 `:env` 是**合并进继承的环境**，所以部署级变量（`RINTO_API`）
不用改代码就能被 pi 继承；只有 per-session 的 id 才需要给 `start_opts` 加 `:env`。

`conversation_id` 的缺席意味着第一阶段**记不了 provenance**：
`document_revisions.source_conversation_id`（`document-working-session.md:174`）
要等 conversations 实现。这是认下的，不找替代方案。

## 与 Task 的关系（消歧）

`document-working-session.md:5` 写着「产品取向：AI 改文档是核心；**不**以 Task 为主模型」，
`:277`「不以 Task 承载 AI 改文档过程」。本文档的客户端场景又在说「领任务」，需要澄清：

被否决的是**用 Task 承载文档编辑过程** —— 那个载体是 conversation + working session，
Task 顶替不了，也不该顶替。

本文档客户端场景里的 Task 是**执行层**：开发者领一个实现任务、读文档、写代码、回报状态。
它消费文档，不承载文档的编辑过程。两者不在同一层，不矛盾。

客户端那半的具体命令面**待 Task 域设计确定**，本文档不定。
`apps/rinto_pmo/lib/rinto_pmo/tasks/` 目前是空目录。

因此客户端 skill 第一版**只写读文档那半**，命名为 `rinto-docs-reference` 而非
`rinto-task-execution`：pi 只把 skill 的 `name` + `description` 常驻上下文
（`core/skills.js:257`），一个描述里承诺「领任务、回报状态」而正文说「未实现」的 skill，
等于常驻着一条假广告。名字随能力长，不随规划长。

## 部署

第一阶段服务端只需三件事，都不改代码：

1. 二进制放进 PATH
2. `rinto-pmo skill install rinto-document-authoring`
3. `RINTO_API`（API base URL，含 `/api/v1`）和 `RINTO_ACTOR_ID`
   进 release 的运行环境（pi 继承）

**要记进 Dockerfile 或部署脚本，不要手动做完就算。**
否则换台机器、重建容器，skill 和二进制静默消失，
表现出来是「AI 突然不会写文档了」—— 这种问题很难查。

### skill 烤进二进制

skill 文件用 `include_str!` 编进 CLI，`skill install` 把它写到 `~/.pi/agent/skills/`。
两个好处：

- **分发只有一个 artifact**。客户端场景尤其重要 —— 开发者 brew/cargo 装一个二进制就够，
  不用另外去取一份 skill 文件
- **skill 与它描述的命令不会版本漂移**。skill 讲的是这个 CLI 自己的用法，
  跟 `--help` 同生命周期，本来就该同一个 artifact

这与「教材从服务端取」不冲突：那条管的是模型照着构造**数据**的词汇（block schema），
服务端拥有；怎么调用这个 CLI 是 CLI 自己的事。

**install 要求显式指定名字，不默认装全部。** 两套 skill 是给不同受众的，
默认装全会悄悄推翻「一个 CLI 两套 skill」的分工。`skill list` 列出可装的。

已存在且内容不同的文件需要 `--force` 才覆盖 —— 装好的 skill 是可编辑的，
静默覆盖会无痕地弄丢别人调过的措辞。

## 明确不做

- 不走 MCP，不写 pi extension
- 不拆两个二进制
- 不用打包方式做能力限制（那是授权问题）
- 第一阶段不改已有文档
- CLI 不暴露 revision 概念（初始 revision 由 backend 自动产生）
- CLI 不做内部重试、不吞冲突（409 / 422 原样转述，重试由 AI 显式决定）
- CLI 不做 block 结构校验（服务端 `BlockOps` 是权威）
- 第一阶段不做 `doc schema` 子命令、不加对应端点（模型不构造结构化数据，没有触发条件）
- 将来真要做时，不把 block schema 烤进二进制
- 第一阶段不做认证
- 客户端命令面本次不定（待 Task 域设计）
