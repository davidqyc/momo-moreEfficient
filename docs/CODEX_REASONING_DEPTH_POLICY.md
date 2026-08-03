# momo-moreEfficient Coding 思考深度使用协议

status=CANONICAL_CODING_REASONING_DEPTH_POLICY
version=1.0
date=2026-08-03
authority=OWNER_ACCEPTED_PROJECT_REASONING_DEPTH_POLICY
source_policy=davidqyc/babyfood@master:docs/CODEX_REASONING_DEPTH_POLICY.md

## 1. 目的

本协议规定本项目向 Codex、Claude Code、Kimi Code 或其他 coding 程序发出正式 Prompt 时，怎样选择并标注模型、思考深度和执行模式。

本项目是极小型效率工具。目标不是沿用大型产品的默认深度，也不是一律开到最高，而是使用能够可靠关闭当前任务的最低充分档位，避免过度设计、无收益延迟和多 Agent 协调成本。

每份正式 coding Prompt 顶部必须显式写明：

```text
Model: <实际模型>
思考深度: 轻度 | 中 | 高 | 极高 | 最高
执行模式: 单 Agent | Ultra
选择原因: <一句话>
```

不得只写“认真一点”“深度思考”“自动选择”，也不得把深度交给 Agent 自行猜测。

---

## 2. 命名

### 2.1 Codex 5.6 Sol

| Codex 界面 | 项目语义 |
| --- | --- |
| `轻度` | Low |
| `中` | Medium |
| `高` | High |
| `极高` | Extra |
| `最高` | Max |
| `Ultra` | 多 Agent 执行模式，不是普通第六档单 Agent 深度 |

硬规则：

- 不写 `X High` 或 `Extra High`；统一使用 `Extra`；
- `最高` 是单 Agent 最高深度；
- `Ultra` 改变执行拓扑，不等于“比最高再多想一点”。

### 2.2 其他 coding 程序

跨工具统一语义：

```text
Low / Medium / High / Extra / Max / Ultracode
```

工具没有对应档位时，不得编造；Prompt 中同时写明项目语义和工具实际选择。

---

## 3. 项目级选择原则

固定优先级：

```text
正确性与账号/数据安全
→ 使用体验与可恢复性
→ 可维护性和开源价值
→ 时延、额度与协调成本
```

选择时检查：

1. 需求是否已经冻结；
2. 改动是机械操作、单文件，还是多文件行为变化；
3. 是否涉及 Token、账号隔离、真实 API 写入、幂等、超时、response loss、恢复或回滚；
4. 错误是否可能造成重复写入、错误覆盖、凭证泄漏、账号串号或大范围返工；
5. 上一轮是否被 Reviewer BLOCK，或同类修复是否已经失败；
6. 是否需要独立反例搜索与证据闭环。

项目规模小意味着多数任务应比 BabyFood 低一档或保持更窄范围；但真实 API 写入安全、结果未知和账号隔离不因代码量少而降级。

---

## 4. 各档位用途

### 4.1 轻度 / Low

用于完全机械、可直接判定对错的工作：

- 读取 PR 状态、SHA、分支和 Issue 状态；
- hash、ZIP 完整性、文件清单和 merge 后 readback；
- 已知位置的拼写、链接或状态字段修正；
- 普通 Ready、merge、删除分支和 closeout。

不得用于实质代码、独立审阅、API 语义或安全逻辑。

### 4.2 中 / Medium

用于低风险、合同已冻结的窄施工：

- 小型文档更新；
- 单文件或少量文件的确定性修复；
- 已知原因的测试调整；
- 无账号、无网络、无状态风险的脚手架和样板；
- 明确审阅意见对应的机械修正。

### 4.3 高 / High

这是本项目实质 Builder 和普通 Reviewer 的常用默认档位：

- 多文件但范围清楚的功能实现；
- 解析器、API client、CLI、缓存或桌面入口的非平凡修改；
- mocked transport、预览、批量流程和测试联动；
- 第一次实现一项边界明确的功能；
- 有明确合同的定向代码审阅。

本项目此前 Issue #2 offline planner、Issue #9 第一版 harness 使用 `高`，与当时“首次、边界清楚、完全离线”的任务性质匹配。

### 4.4 极高 / Extra

仅在小项目中仍存在实质高风险或已触发升级条件时使用：

- Token 与账号隔离；
- 真实写入门禁、幂等、超时、response loss、unknown outcome；
- 写前状态、写后回读、人工恢复和回滚证据；
- 凭证指纹、防串号和敏感信息边界；
- Reviewer 已给出实质 BLOCK，且修复跨多个安全不变量；
- 同一问题普通修复未关闭根因；
- 进入真实副账号测试前的最终 write-path 审阅。

当前 PR #10 的阻断修复属于此档：上一版虽通过测试，但 Reviewer 发现错误 update payload、错误 readback 合同、未记录 highlight、写入结果未知不落状态和不可用的预览/回滚设计。它同时涉及 response loss、恢复和账号安全，因此从此前的 `高` 升为 `极高`。

### 4.5 最高 / Max

默认关闭，仅用于：

- `极高` 修复后仍存在结构性 BLOCK；
- 多轮仍无法关闭真实写入、恢复或账号串号根因；
- 主账号接入前的最终独立安全审阅；
- 真实数据迁移、批量回滚或不可轻易返工的最终裁决。

使用前必须说明 `极高` 为什么不足。不得用于普通 Builder、文档、merge 或已知小修。

### 4.6 Ultra / Ultracode

本项目默认关闭，通常不适合极小应用。

只有以下条件全部成立时才可启用：

1. 至少三条真正独立的长工作流；
2. 各 lane 不共享可写文件；
3. 并行显著提高反例覆盖或缩短时间；
4. 有主 Agent 统一真值和综合；
5. 收益明显高于协调与 token 成本。

单一 Builder、一个 PR 修复、普通审阅、merge 和同一 worktree 写入均不得使用 Ultra。用户不承担手工多 Agent 编排。

---

## 5. 角色默认值

| 角色 / 工作 | 默认档位 | 升级条件 |
| --- | --- | --- |
| PR 状态、merge、readback、ZIP 机械核验 | `轻度` | 坐标冲突或异常 diff → `中/高` |
| 小型 docs 或已知单点修复 | `中` | 多文件行为或合同冲突 → `高` |
| 普通功能 Builder | `高` | Token、真实写入、unknown outcome、恢复 → `极高` |
| 普通定向 Reviewer | `高` | write path、账号隔离、恢复或已 BLOCK → `极高` |
| 真实副账号写入前安全审阅 | `极高` | 多轮仍 BLOCK 或主账号最终门禁 → `最高` |
| Coordinator 生成普通 Builder Prompt | `中/高` | 多个安全合同和恢复路径 → `极高` |

Reviewer 深度不得低于所审问题的实质复杂度。Fresh context 和审阅独立性优先于机械地“高一档”。

---

## 6. 自动升级

命中任一项，至少升一级：

- 上一轮没有关闭根因；
- Reviewer 给出实质正确性或安全 blocker；
- 同类修复失败两次；
- 涉及幂等、重试、response loss、restart、恢复或回滚；
- 涉及 Token、账号身份、权限或多个 identity domain；
- 需要证明某类危险行为“不发生”；
- 错误可能造成凭证泄漏、账号串号、重复写入、错误覆盖或不可恢复数据问题。

`Ultra` 不是自动升级结果，必须另行通过并行 ROI 检查。

---

## 7. 自动降级

以下均成立时可以降低一档：

- 合同和根因已经冻结；
- 改动位置与预期 diff 明确；
- 有直接决定性的自动验证；
- 不涉及新网络、Token、真实账号、状态或恢复；
- 只是机械修正、状态同步、证据包装、merge 或 closeout。

不得因为此前连续使用 `高`，就让后续 merge 或 readback 继续使用 `高`。

---

## 8. Prompt 写法

### 8.1 Codex 5.6 Sol

普通功能：

```text
Model: GPT-5.6 Sol
思考深度: 高
执行模式: 单 Agent
选择原因: 多文件但边界清楚的实质功能实现
```

高风险修复：

```text
Model: GPT-5.6 Sol
思考深度: 极高
执行模式: 单 Agent
选择原因: 涉及真实写入结果未知、恢复状态和账号隔离，且上一轮被 Reviewer BLOCK
```

机械 closing：

```text
Model: GPT-5.6 Sol
思考深度: 轻度
执行模式: 单 Agent
选择原因: 只做 PR 状态核验、合并和 readback
```

### 8.2 英文界面工具

```text
Model: <model>
Reasoning: Low | Medium | High | Extra | Max
Execution: Single agent
Selection reason: <one sentence>
```

---

## 9. Coordinator 职责

Coordinator 必须：

- 在每一份 coding Prompt 中自行选择并标注模型、深度和执行模式；
- 用一句话说明选择原因；
- 每轮根据新风险、Reviewer 结果和任务收敛程度重新判断，不沿用上一轮档位；
- 不把档位选择转嫁给 Owner；
- 不让 Owner 手工编排多 Agent；
- closing 时判断下一轮应升级、保持或降级。

只有当两种模式带来显著不同的费用、时间或并行风险，且无法按本协议判断时，才询问 Owner。

---

## 10. 新会话和任务入口

开始任何 coding Prompt 设计或代码任务前，必须读取：

```text
docs/CODEX_REASONING_DEPTH_POLICY.md
```

新 Issue 或 PR 的执行 Prompt 也必须显式引用本协议。不得依赖聊天中的旧档位记忆。

---

## 11. 边界

本协议只决定模型思考深度和执行模式，不自动授权：

- 进入真实 API 阶段；
- 配置 Token；
- 对副账号或主账号写入；
- 删除、回滚或批量更新；
- 合并 PR；
- 使用 Ultra；
- 跳过测试、独立审阅或 Owner 的产品决定。
