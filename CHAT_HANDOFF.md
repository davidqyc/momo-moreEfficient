# momo-moreEfficient 轻量会话接管入口

status=CANONICAL_LIGHTWEIGHT_CHAT_HANDOFF
version=1.0
date=2026-08-09

本项目规模较小，不使用 BabyFood 式完整项目记忆体系。换对话时只维护一层轻量远端接管：**实时 GitHub `main` 是事实权威，聊天只是临时上下文。**

## 1. 新对话从哪里开始

收到接管文档后，先读取实时：

```text
davidqyc/momo-moreEfficient@main
docs/NEW_CHAT_BOOTSTRAP_PROMPT.md
docs/PROJECT_STATE.md
AGENTS.md
docs/decision-log.md
```

然后读取 `docs/PROJECT_STATE.md` 指向的当前 GitHub Issue、最新评论、相关 PR/commit；只有当前任务需要时才读取 `docs/product-and-api-plan.md`、CHANGELOG、历史 Issue/PR 或代码。

不要平均通读整个仓库，也不要让 Owner 重新讲旧聊天。

## 2. 各类事实放在哪里

```text
当前做到哪 / 唯一下一步 / 当前边界
→ docs/PROJECT_STATE.md

已经确认、长期有效的产品/安全决策
→ docs/decision-log.md

当前工程任务、验收、阻断、实时事实
→ GitHub Issue + 最新评论

发布和用户可见版本变化
→ CHANGELOG.md + release / PR / commit

长期产品/API 背景
→ docs/product-and-api-plan.md
```

本项目**不额外建立** PD/PL/OT、开发编年史、Incident registry、JSON memory receipt 或 verifier；除非项目未来明显变大并出现真实维护收益。

## 3. 什么时候更新 `PROJECT_STATE.md`

只在以下情况更新：

- 当前主任务/Issue 改变；
- 当前唯一下一步改变；
- 一个重要实现/发布 milestone 已合并；
- 出现会影响下一会话判断的阻断或路线变化；
- 准备换对话，发现状态页已落后于实时远端。

普通小修、测试数字、机械 PR metadata、无新结论的 PASS 不需要污染状态页。

新的长期产品/安全决定仍按 `AGENTS.md` 写入 GitHub Issue，并在 Owner 接受后进入 `docs/decision-log.md`。

## 4. 换对话前的旧中枢动作

```text
读取实时 main / 当前 Issue / 最近 merge
→ 如有必要同步 decision-log
→ 更新 docs/PROJECT_STATE.md 到 current truth
→ 必要时做 docs-only PR / ordinary merge
→ 回读最终 main
→ 基于最终 main 生成新的 Markdown 接管 Prompt
→ 在旧对话直接附加文件卡
```

交接附件是 Prompt + snapshot，不替代实时远端。附件中的 SHA 永远只是生成坐标，不是回滚锚点。

若本轮没有任何远端状态需要更新，也仍应从最新 `main` 重新生成一份新的接管文档，不长期复用旧附件。

## 5. 标准交接文档

默认文件名：

```text
momo-moreEfficient_新对话接管Prompt_<YYYY-MM-DD>.md
```

最低内容：仓库/分支、sourceMainSha（snapshot only）、当前主任务、唯一下一步、已接受决定入口、当前风险边界、新对话读取顺序、首次回复格式。

不要把完整聊天、全部测试日志或所有历史 PR 塞进附件。

Owner 的标准操作只有一步：把该 Markdown 作为新对话第一条消息发送；客户端要求文字时附一句：

```text
按附件执行。
```

## 6. 纯文字兜底

只有附件不可用时，使用：

```text
继续 momo-moreEfficient。读取 davidqyc/momo-moreEfficient@main 的 CHAT_HANDOFF.md，并按实时远端接管。
```

## 7. 边界

本接管机制只管理远端状态与对话切换，不自动授权真实账号写入、Token 使用、删除、未授权产品实现、破坏性 Git 或其它 `AGENTS.md` 禁止事项。
