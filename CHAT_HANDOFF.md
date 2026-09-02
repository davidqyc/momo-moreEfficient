# momo-moreEfficient 轻量会话接管入口

status=CANONICAL_LIGHTWEIGHT_CHAT_HANDOFF
version=1.1
date=2026-09-02

本项目规模较小，不使用 BabyFood 式完整项目记忆体系。换对话时只维护一层轻量远端接管：**实时 GitHub `main` 是事实权威，聊天只是临时上下文。**

## 1. Fresh Chat 第一轮

第一轮只读：

```text
davidqyc/momo-moreEfficient@main
→ docs/PROJECT_STATE.md
→ 当前 primary Issue metadata/body + exact current PR/commit named by state
→ latest explicit Owner instruction
```

不要在 takeover 第一轮先全文加载：

```text
AGENTS.md
docs/decision-log.md
docs/product-and-api-plan.md
CHANGELOG.md
历史 Issue/PR
全部 agent-skills bodies
当前 Issue 的全量 comments
```

这些按当前动作 JIT 读取。

## 2. Issue comments context guard

当前 GitHub connector 的 `fetch_issue_comments` 会跨所有分页返回整条历史时：

```text
BULK_ISSUE_COMMENT_HISTORY_DURING_TAKEOVER=FORBIDDEN
```

不要把“当前 Issue 最新评论”实现成 all-pages 全量抓取。

优先：

```text
PROJECT_STATE
→ exact PR/commit / known current checkpoint
→ Issue metadata/body
→ only when one comment is genuinely decision-bearing: bounded/exact retrieval
```

项目较小不代表可以无上限累积 Issue history；fresh Chat 的目标是保留 current truth，不是重放讨论史。

## 3. Coordinator / Builder split

稳定 routing：

```text
ChatGPT = Coordinator
default heavy Builder = Codex / GPT-5.6 Sol
```

ChatGPT Coordinator 负责：current truth、产品/安全 adjudication、Builder/Reviewer dispatch、返回结果审阅、普通 merge/readback、轻量 docs/state sync。

多文件实现、长测试/debug、substantive repair 默认留给 Builder execution surface，不要在 Coordinator 主 Chat 里连续吞掉：

```text
implementation → tests → repair → review → merge → next unrelated feature
```

这不是新增 Owner 授权门；自然 checkpoint 后下一 turn 可继续已授权主线。

## 4. 各类事实放在哪里

```text
当前做到哪 / 唯一下一步 / 当前边界
→ docs/PROJECT_STATE.md

长期产品/安全决定
→ docs/decision-log.md

当前工程任务、验收、阻断、实时事实
→ GitHub Issue + PR / commit

发布和用户可见版本变化
→ CHANGELOG.md + release / PR / commit
```

不新增 PD/PL/OT、Chronicle、Incident registry、JSON memory receipt 或 verifier，除非未来出现真实维护收益。

## 5. JIT reads

真正准备 coding/review dispatch 时再读：

```text
AGENTS.md
docs/AGENT_SKILLS_CONNECTOR.md
live agent-skills model/reasoning/workspace/review Skills
```

需要长期决定时才读 `docs/decision-log.md`；需要背景时才读 `docs/product-and-api-plan.md`。

## 6. State maintenance

只在以下情况更新 `PROJECT_STATE.md`：

- 当前主任务/Issue 改变；
- 当前唯一下一步改变；
- 一个重要实现/发布 milestone 已合并；
- 出现会影响下一会话判断的阻断或路线变化；
- 准备换对话，发现状态页已落后于实时远端。

普通小修、测试数字、机械 PR metadata、无新结论的 PASS 不污染状态页。

## 7. Handoff closeout

```text
读取实时 main / 当前 Issue metadata / 最近 merge
→ 必要时同步 decision-log / PROJECT_STATE
→ normal docs-only merge/readback when required
→ 生成新的 Markdown handoff
```

不要把完整聊天、全部测试日志或所有历史 PR/comments 塞进附件。

## 8. Authorization boundary

本接管机制不自动授权：

```text
真实账号写入
Token / credential use
delete
未授权产品实现
release / publish
破坏性 Git
```

## 9. First reply

```text
momo-moreEfficient 接管：PASS / BLOCK
live main：<sha>
当前主任务：<Issue / gate>
本轮读取范围：PROJECT_STATE + exact current object
全量 Issue comments：NO
当前唯一下一步：<一句>
需要 Owner 决策：是 / 否
需要 Owner 操作：是 / 否；若是只写一个动作
主要安全/授权边界：<一句>
ROI 裁决：PROCEED_NOW / DEFER / REJECT
```

## 10. 纯文字兜底

```text
继续 momo-moreEfficient。只读 davidqyc/momo-moreEfficient@main 的 docs/PROJECT_STATE.md 与其中命名的 exact current object；不要抓取 Issue 全量 comments，并按实时 routing 接管。
```