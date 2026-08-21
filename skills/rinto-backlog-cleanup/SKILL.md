---
name: rinto-backlog-cleanup
description: 在 Rinto 里作废被新方案取代的旧任务。当一份新的方案文档已经落库成任务、需要清掉它顶替掉的旧活，或用户说「这些任务不用做了」「新方案取代了之前的安排」时使用。逐条向用户确认后才调用 cancel，不自行决定。
---

# 作废被取代的旧任务

Rinto 里改变计划的方式是**写新文档**，不是回头改老任务。新方案落库之后，
被它顶替掉的旧活还留在 backlog 里 —— 这个 skill 就是把那些活作废掉。

**这不是执行任务的流程。** 领取和完成任务看 `rinto-docs-reference`。

## 一条硬规矩：你提名单，人点头

**在用户逐条确认之前，一个 `cancel` 都不要发。**

判断「这条活是不是被取代了」需要知道为什么当初要做它、新方案打算怎么覆盖它 ——
这些你只看得到一部分。而作废是**记录团队放弃了这项工作**，不是整理数据。

正确的做法是：列出候选、说明每条为什么可疑、请用户确认。用户砍掉几条、加上几条，
都很正常，那正是这一步存在的意义。

## 1. 找出候选

已经落库的旧方案，它产出的活全都指向它：

```sh
rinto-pmo task list <project-slug> --document-id <旧方案文档 id> --live
```

`--live` 只列还没结束的活。**已经 done 的不要碰** —— 那些工作已经发生了，
作废它们等于否认已经做过的事。

不知道旧方案的文档 id 时，从任务反查：

```sh
rinto-pmo task show <task-id>
```

看不出取代关系时，把整个项目还没做的活拉出来自己判断：

```sh
rinto-pmo task list <project-slug> --live
```

## 2. 逐条判断，并说出理由

对每条候选，向用户说明：

- 这条活是什么（标题 + 描述里的关键点）
- 新方案里的哪一部分顶替了它
- 它现在的状态 —— **`in_progress` 的要单独点出来**，有人已经动手了

`rinto-pmo task show <task-id>` 给出全部字段。

## 3. 确认后作废

```sh
rinto-pmo task cancel <task-id>
```

### summary 节点不能 cancel

它不接受任何状态转换，状态是从子任务算出来的。**要作废一整块，把它下面的
work 任务全部 cancel** —— 全部作废之后，summary 自己就会显示为 cancelled。

先看清楚这一块下面有什么：

```sh
rinto-pmo task list <project-slug> --parent-id <summary-id>
```

对 summary 发 cancel 会报错。**看到错误不要重试**，去取消它的子任务。

### 不要用 delete

`delete` 是给「本就不该存在的记录」用的 —— 建错了的、重复的。
被取代的工作**曾经是真实的计划**，`cancel` 保留这个记录，`delete` 抹掉它。

### 不要 release

`release` 是「我做不动了，换个人」，工作仍然要做。跟作废是两回事。

## 4. 把理由留在对话里

**Rinto 现在没有地方记录「为什么取消」** —— `cancel` 只改状态，任务上没有备注字段。

所以作废完之后，在对话里向用户复述一遍：作废了哪些、各自为什么。这段话是这次决定
唯一留得下的痕迹，用户要存的话得自己存（比如写进新方案文档里）。

不要假装系统记住了。

## 命令权威

本文描述工作流，不复制参数细节。当前二进制支持什么以帮助为准：

```sh
rinto-pmo task --help
rinto-pmo task list --help
rinto-pmo task cancel --help
```
