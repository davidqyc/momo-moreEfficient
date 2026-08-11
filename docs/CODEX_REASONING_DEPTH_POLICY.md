# momo-moreEfficient Coding Reasoning Depth Policy

status=CANONICAL_CODING_REASONING_DEPTH_POLICY
version=2.0
date=2026-08-12

本文件只负责**模型 / effort / execution topology 路由**。产品事实和当前任务以 `AGENTS.md`、`docs/PROJECT_STATE.md`、当前 Issue 为准。

## 1. 正式 Prompt 头

实质 coding / review Prompt 仍写：

```text
Model: GPT-5.6 Sol
思考深度: 轻度 | 中 | 高 | 极高 | 最高
执行模式: 单 Agent | Ultra
选择原因: <一句话>
```

不要把“选择 effort”本身变成流程项目；同一已冻结任务的机械 follow-up 可沿用或降低，不必每个小节点重新论证。

## 2. 默认路由

### 轻度 / Low

用于纯机械、可直接验错的工作：SHA、状态回读、merge、链接/拼写修正、ZIP/hash 机械核验。

### 中 / Medium

用于确定性的小改动：小型 docs、单文件低风险修复、简单 UI/测试调整。

### 高 / High — 默认 Builder / Reviewer

用于普通实质功能：多文件但边界明确的 parser、UI、API client、fake transport、Preview、普通 bug 和定向 review。

**momo-moreEfficient 的普通实质 coding 默认从 `高 / 单 Agent` 开始。**

### 极高 / Extra — 真实写入风险档

只在确实涉及以下内容时使用：

- Token / Keychain / 账号身份与 ownership；
- 新真实写入操作；
- 幂等、response loss、unknown outcome；
- readback / recovery / rollback 语义；
- Reviewer 已发现跨多个安全不变量的实质 blocker。

### 最高 / Max

默认关闭。只有 Extra 后仍有结构性 blocker、重大真实数据迁移/恢复、或最终高风险裁决才启用。

### Ultra

默认关闭。只有至少三条真正独立、可隔离的长 lane 且并行 ROI 明显为正时才启用。单一 Builder、一个 PR、普通 review 不使用 Ultra。

## 3. 不要用更高 effort 掩盖错误的产品范围

在升级到 Extra/Max 或增加 Agent 之前，先问：

1. 这是不是低频边缘情况？
2. 有没有便宜安全的人工 fallback？
3. 复杂度来自真实风险，还是来自我们试图自动处理一个不该自动处理的问题？

如果合同已经超过一屏、准备新增平行 executor/approval/binding 栈，或保护机制明显大于机制本身，**不要继续提高 Codex effort**。

按 `docs/AGENT_SKILLS_CONNECTOR.md` 先路由 fresh Claude/Fable/Opus 做独立 simplification / architecture re-frame，再决定是否继续施工。

## 4. Review 深度

- 普通 parser/UI/block-only guard：Builder High 自测 + Coordinator 定向检查通常足够；
- 新真实写入类型、credential/identity、readback/recovery：Fresh Reviewer 至少 Extra；
- 不因为测试很多、文件很长就自动升级；看现实损失半径和错误类型。

## 5. Claude 路由

Claude coding / architecture Agent 的正式输入 Prompt 和 Agent 自生成报告默认全英文。

- 普通架构敏感 fresh review：Opus 5 / Extra / Single Agent；
- 最高能力、长程 architecture reset：Fable 5 / Max / Single Agent；
- 不为了“更强”默认使用 Ultracode；本项目通常是一条连续判断链，单 Agent 更合适。

具体 Claude 产品端映射以 `davidqyc/agent-skills` 的 `claude-model-effort-routing` 与项目 instance 为准。

## 6. Durable rule

```text
先判断产品是否值得做
→ 再选择最小机制
→ 再选择足够的模型/effort
```

禁止倒过来用高 effort 把低 ROI 功能做得更完整。
