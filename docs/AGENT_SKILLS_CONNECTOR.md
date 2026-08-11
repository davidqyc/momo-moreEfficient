# AGENT_SKILLS_CONNECTOR

status=ACTIVE
source_repo=davidqyc/agent-skills
source_branch=main
project_instance=instances/momo-moreEfficient.yml

本文件只负责把 momo-moreEfficient 路由到 Owner 的跨项目 Agent Skills。不要把 Skill 全文复制进本仓库。

## 1. 读取顺序

Owner 当前明确指令
> 当前 GitHub Issue / 最新评论
> `docs/decision-log.md`
> `docs/PROJECT_STATE.md`
> 本项目 `AGENTS.md`
> 本 connector + project instance
> 跨项目 Skill 默认

跨项目 Skill 不覆盖本项目当前产品事实。

## 2. Required cross-project skills

从 `davidqyc/agent-skills@main` 读取：

- `skills/owner-coordinator-high-value-delivery/SKILL.md`
- `skills/anti-overengineering-mechanism-routing/SKILL.md`
- `skills/fresh-context-architecture-reset/SKILL.md`
- `skills/mechanism-memory-and-certainty-routing/SKILL.md`
- `skills/coding-reasoning-depth-routing/SKILL.md`
- `skills/claude-model-effort-routing/SKILL.md`
- `skills/claude-code-english-output-boundary/SKILL.md`
- `skills/multi-file-agent-dispatch/SKILL.md`
- `skills/cloud-canonical-agent-handoff/SKILL.md`

再读取：

`instances/momo-moreEfficient.yml`

## 3. momo-specific routing

### Normal bounded implementation

```text
Builder = Codex / GPT-5.6 Sol
Depth = High
Execution = Single Agent
```

### Real-write / credential / recovery change

```text
Builder or Fresh Reviewer = GPT-5.6 Sol Extra or Claude Opus 5 Extra
Execution = Single Agent
```

具体看任务类型，不做永久模型排名。

### Architecture simplification checkpoint

若出现以下任一信号，在继续派 Builder 前切 fresh architecture Agent：

- 小机制合同超过一屏；
- 低频 edge case 准备新增平行 executor / approval / binding / recovery stack；
- proof/gate/harness 的复杂度超过被保护机制；
- 同一机制连续修补而主要新增证明层；
- Owner 明确质疑复杂度或 ROI。

默认：

```text
Model = Fable 5
Product effort = Max
Speed = Standard
Execution = Single Agent
Prompt language = English
Output language = English
Role = independent simplifier / architecture re-framer
```

如果任务规模不需要最高能力，可用 Opus 5 / Extra；不要默认 Ultracode。

成功标准是减少状态、合同或机制，或证明现有简单路线已足够；如果 Claude 只提出更大框架，不采用。

## 4. Lightweight-product route

momo-moreEfficient 是小型效率 App。默认顺序：

```text
real user pain / real safety risk
→ cheapest safe fallback
→ minimum mechanism
→ bounded implementation
→ proportionate validation
→ real use
```

不是：

```text
new edge case
→ complete automation contract
→ new safety stack
→ full proof suite
```

低频 edge case 且人工 fallback 清楚、便宜时，默认 guard + 提示 + defer。

不要使用固定“发生 N 次”作为硬 Gate；看实际频率、损失半径、fallback 成本和是否已有真实外部用户。

## 5. Review / rehearsal route

Fresh independent review 默认只保留给：

- 新真实写入操作类型；
- credential / Keychain / identity / ownership 变化；
- readback / unknown-outcome / recovery 变化；
- 第一次外部分发 build；
- 已出现跨多个安全不变量的实质 blocker。

Parser、UI 文案/布局、block-only guard、docs/test-only change 默认 Builder 自测 + Coordinator 定向检查；需要时加一次 Owner smoke。

实体 rehearsal 只在新写入类型第一次真实使用或设备 lifecycle 行为真正变化时默认需要。

## 6. Claude language boundary

所有 Claude coding / review / architecture Agent：

```text
Prompt language: English
Output language: English
```

中文 Owner 输入由 Coordinator 保真翻译；必须精确保留的中文 UI/错误/来源作为 task data 引用。

## 7. Current reset rule

2026-08-12 architecture reset 的长期结论：

- 当前 merged App 不需要大重构；
- 优先停止增加产品范围，而不是把现有复杂度抽象成框架；
- 不自动补完整 phrase CRUD；
- real use 的信息增益高于下一项假设性功能时，停止工程。
