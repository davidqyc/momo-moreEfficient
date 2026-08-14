# AGENTS.md

本文件约束 Codex 及其他 coding Agent 在本仓库中的工作方式。

## 1. 事实来源与优先级

遇到冲突时按以下顺序处理：

1. Owner 当前明确指令；
2. 当前 GitHub Issue 及其最新评论；
3. `docs/decision-log.md` 中仍有效的长期产品/安全决定；
4. `docs/PROJECT_STATE.md` 的当前主线与唯一下一步；
5. `docs/product-and-api-plan.md`、README、当前代码与测试；
6. `docs/AGENT_SKILLS_CONNECTOR.md` 指向的跨项目 Agent 工作流规则；
7. 聊天记录或 Agent 自行推断。

跨项目 Skill 只约束协作与路由，不得覆盖本项目当前产品事实。

## 2. 开始任务前必须读取

每次实质 coding / review 会话至少：

1. 确认仓库、分支和实时 `origin/main`；
2. 读取本文件、`docs/PROJECT_STATE.md`、`docs/decision-log.md`、`docs/CODEX_REASONING_DEPTH_POLICY.md`；
3. 读取 `docs/AGENT_SKILLS_CONNECTOR.md`；
4. 读取当前被分配 Issue 全文及最新评论；
5. 只读取与当前任务直接相关的其他代码/文档；
6. 开工前用很短的计划写清目标、拟改文件、验证方式、风险和不做事项。

如果没有明确 Issue 或 Owner 明确施工指令，不自动扩展工程范围。

## 3. 轻项目优先：先过 ROI 门，再写合同

这是一个小型效率工具，不是通用 Maimemo CRUD 客户端。

发现新边缘情况时，Coordinator / Agent 在建 Issue 或写实现合同前先回答：

1. 现实中多久会发生一次？
2. 最便宜、最清楚的安全人工 fallback 是什么？
3. 如果不自动化，现实最坏后果是什么？

默认规则：

- 低频边缘情况 + 有便宜人工 fallback → 默认做 guard / 提示 / defer，不自动化；
- 只有重复造成真实摩擦，或不自动化存在明确的数据损失、重复写、错误覆盖、凭证/身份风险时，才值得增加自动机制；
- 不用固定“出现 N 次”作为新 Gate；看真实频率、损失半径和 fallback 成本；
- 先服务 Owner 当前真实使用，再服务已出现的小规模外部用户；不要提前为假设中的大众用户补完整能力；
- 优先删范围、延后能力，不因为文件长就先做抽象重构；
- 禁止因为解释完整、对称或“CRUD 应该齐全”而自动补功能。

### 3.1 过度工程触发器

命中任一项时，停止继续派 Builder，先做一次独立简化/架构重表达：

- 一个低频小机制的实现合同已经超过一屏；
- 为一个新边缘情况准备新增平行 executor / approval / binding / recovery 栈；
- 保护机制的复杂度开始明显超过被保护机制本身；
- 同一机制连续两轮主要在加 Gate、digest、validator、Harness 或 proof；
- Owner 明确质疑 ROI、复杂度或“是否做重了”。

优先按 `docs/AGENT_SKILLS_CONNECTOR.md` 路由到 fresh Claude/Fable/Opus simplification checkpoint，再决定是否让 Codex施工。

## 4. Issue 与施工粒度

默认：**一个 Issue = 一个用户可见结果**。

- 不把一个小功能机械拆成 4a/4b/4c/4d 多个工程回合；
- 只有新的真实写入类型、真实账号权限边界、不可逆迁移等风险确实需要分段授权时才拆 runtime gate；
- task contract 应尽量一屏内说清，超过后先检查是不是机制本身过大；
- Issue 存在不代表必须实现；没有现实 ROI 时可以 DEFER / DROP。

默认工程流：最新 `main` → Issue branch → 最小改动 → 定向测试 → commit → Draft PR。

已授权路线内、所需验证已通过且没有新风险边界时，机械 merge/closeout 不需要再向 Owner 收一次同义确认；但禁止 force push、历史改写、reset/clean/stash/rebase 等高破坏动作，除非 Owner 单独授权。

## 5. 真实凭证与个人数据

绝对禁止提交：

- 真实 Maimemo Token、Cookie、刷新凭证；
- 用户完整学习记录、私人例句批次、未脱敏 API 响应；
- `.env`、私钥、证书、Keychain 导出、账号身份原值；
- 未脱敏日志、截图、崩溃转储。

凭证边界：

- iOS：按 D-016，仅保存到本设备 Keychain，`kSecAttrAccessibleWhenUnlockedThisDeviceOnly`，non-sync；
- 具备写入能力的 CLI/macOS 本地工具：按 D-013，仅隐藏交互输入、进程内存，不使用 argv/env/.env/config/clipboard automation；
- Issue #107 的单请求、语义只读 Recipe 是经 Issue 明确授权的窄例外：只读取会话级 `MAIMEMO_TOKEN`，不支持 argv、`.env`、配置文件或持久化；不得把该例外扩展到任何写入路径；
- Token 不进入日志、History、UI 持久状态、review artifact 或 Git。

发现疑似真实凭证进入 Git 历史时立即停止并报告；不要靠后续删除文件假装历史已安全。

## 6. 真实 API 写入的最低安全底线

真实写入继续保留这些最小必要机制：

- Preview 不是授权；
- 写前显式用户批准；
- stale state 可能导致错误写入时，POST 前 fresh authenticated preflight；
- 每个 changed item 最多一次 POST；
- POST 不自动 retry；
- dispatched POST 后立即 authenticated GET readback；
- uncertain POST 只允许 GET-only recovery；
- UPDATE 只能绑定到明确的 authenticated-user record；歧义时阻断；
- 不自动 DELETE / rollback / replay；
- 不发送 undocumented request fields；
- unknown/malformed server schema fail closed。

不要把每一条安全底线都复制成新的平行架构。新增 binding/state/type 必须能用一句话说明：它防止了现有机制尚未防住的哪个现实错误写入。

## 7. Review、rehearsal 与证据强度

Fresh independent review 默认保留给这些高价值变化：

- 第一次新增一种真实写入操作；
- Token、Keychain、账号身份/ownership 边界变化；
- readback / unknown-outcome / recovery 语义变化；
- 第一次面向外部用户分发 build；
- Reviewer 已发现实质安全/正确性 blocker，修复跨多个安全不变量。

以下默认不需要 fresh independent review：

- parser；
- UI 文案/布局；
- 只会阻断、不会新增写能力的 guard；
- docs / test-only / mechanical change。

这些通常使用：Builder 自测 + Coordinator 定向 diff 检查 + 必要时一次 Owner smoke。

实体 iPhone rehearsal 默认只在“新的真实写入类型第一次进入生产”或真实设备 lifecycle 行为确实改变时使用。不要为普通 parser、文案或 block-only guard制造真机 Gate。

### 7.1 Review ZIP

Review ZIP 不是每次改文件的默认交付物。

只有以下情况默认需要：

- 交给 fresh / out-of-band Reviewer；
- fresh conversation 必须靠文件包独立复现；
- 当前 Issue 明确要求；
- Owner 明确要求。

普通 Builder→Coordinator 同一远端 PR 流程可直接依靠 exact commit/PR diff、测试结果和 GitHub readback，不制造无信息增益的 ZIP 仪式。

## 8. 模型与架构路由

正式 coding Prompt 继续写：

```text
Model: GPT-5.6 Sol
思考深度: 轻度 | 中 | 高 | 极高 | 最高
执行模式: 单 Agent | Ultra
选择原因: <一句话>
```

但不要把“选择 effort”本身变成项目。

项目默认：

- 普通实质 Builder：GPT-5.6 Sol / 高 / 单 Agent；
- 真实写入、凭证、身份、unknown outcome、recovery：极高；
- 机械状态/merge/docs 小修可降到中或轻度；
- 最高与 Ultra 默认关闭。

如果问题已经从“实现”变成“这个表示/架构是不是做重了”，不要只提高 Codex effort；按 connector 路由 fresh Claude/Fable/Opus 做简化裁决。

Claude coding/architecture Agent 的正式 Prompt 与 Agent 自生成报告默认全英文；Owner 中文需求由 Coordinator 保真翻译，中文产品文案作为精确任务数据保留。

## 9. 当前产品优先级

**不要在本文件维护动态优先级列表。**

当前 primary Issue、唯一下一步、open product PR 和阶段性边界只看：

`docs/PROJECT_STATE.md`

## 10. Owner 交互

需要 Owner 决策时，必须是后果真正不同的产品/风险选择；不能把内部技术编排伪装成产品决策。

需要 Owner 操作时：

- 一次只给一个最具体动作；
- 说明应该看到什么；
- 异常时在哪里停止；
- Agent 能自行读取/恢复的内容不得让 Owner 反复搬运。

默认连续推进已授权主线；不要让 Owner 在每个机械节点回复“继续”。

## 11. 完成定义

任务完成至少要求：

- 用户可见目标达成或 blocker 被明确关闭；
- 只跑与风险相称的验证，不用测试数量冒充产品进度；
- 无真实凭证/私人数据进入 Git；
- 失败路径不会静默破坏；
- Issue/PR 记录必要的真实结果与剩余风险；
- 下一步通过 ROI 门；如果继续工程不如实际使用提供的信息多，默认停止开发并进入真实使用。
