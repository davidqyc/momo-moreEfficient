# momo-moreEfficient Current Project State

status=ACTIVE_LIGHTWEIGHT_PROJECT_STATE
updatedAt=2026-08-11
sourceMainSha=acab0613e7ada71d559bca658ab9bf0e8f22d704
sourceMainShaIsSnapshotOnly=true

## 1. Authority

本文件只保存**当前做到哪、当前唯一下一步和当前边界**。实时 `main`、当前 GitHub Issue/最新评论、PR/commit 和 Owner 最新明确决定始终优先。

历史原因和长期决定不要重复维护在这里：

```text
长期决定 → docs/decision-log.md
任务合同/验收/阻断 → 当前 GitHub Issue
发布变化 → CHANGELOG.md
长期 API/产品背景 → docs/product-and-api-plan.md
```

## 2. Current truth

```text
REPOSITORY=davidqyc/momo-moreEfficient
DEFAULT_BRANCH=main
PUBLIC_REPOSITORY=true
CURRENT_MAIN_AT_SNAPSHOT=acab0613e7ada71d559bca658ab9bf0e8f22d704
CURRENT_PRODUCT_VERSION=v0.1.0
CURRENT_PRIMARY_ISSUE=#4
CURRENT_UNIQUE_NEXT=ISSUE_4_IMPLEMENTATION_PLAN_AND_OFFLINE_BUILD
OPEN_PRODUCT_PR=none
ACTIVE_WIP=none
```

当前已完成：

- `v0.1.0` 的释义批量录入闭环、显式主账号 opt-in、真实主账号 dry-run / CREATE / UPDATE 与写后回读均已完成；
- macOS 本地日常 UI 已合并并完成 Owner 真机验收；
- 轻量 iOS companion 已完成实现、独立审阅、实体 iPhone 安装与真实主账号 Preview；`sphere` UPDATE canary 与 `incentive` CREATE canary 均已真实写入并鉴权回读；
- iOS Token 使用仅本设备 Keychain（D-016）；stale Preview、AppIcon、非敏感本地 History/receipt 与活动草稿分离均已完成；
- #73 / PR #74 已完成 mixed-batch remainder preservation。随后真实 10 条批次在实体 iPhone 完成：CREATE 8/8 + UPDATE 2/2，两个 History receipt，最终编辑器清空，10/10 成功；
- #75 / PR #77 已完成已授权执行的可见进度与有限后台保护：普通切 App / 来电不会因 scenePhase 被主动取消；系统回收后台时间时安全停止，不自动 replay/resume；
- #78 / PR #79 已完成进行中 Preview 的 interruption resilience：普通短暂后台可继续/完成；若后台时间到期则干净中断；前台返回不会重复启动 Preview，也不会复活旧 approval；
- #76 / PR #80 已完成 mixed actionable batch 的最终日常 UX：一次 Preview → 一次 Run → 一次 native confirmation → 内部自动 CREATE 再 UPDATE。Owner 已在实体 iPhone DEBUG rehearsal 验收中确认 CREATE 期间切 App 后仍可继续安全确认并自动 UPDATE，无第二次 Preview/确认；
- execution-time whole-batch fresh preflight 继续保留，但 UI 只显示 `安全确认中…`；逐项 `n/N` 只用于真实 CREATE/UPDATE 写入进度；
- phrase/example 路线已由 Owner 于 2026-08-11 明确选为当前产品优先级；来源/origin 是必须可靠写入并回读的 phrase-specific 门槛，英文目标高亮、中文翻译字符/语义范围和精确三标签 round-trip 均为 best-effort，不再阻断产品完成；
- 既有副账号 phrase CREATE 已真实证明 `origin == 自编` 随 documented request 写入并经 authenticated GET 回读；2026-08-11 当前第一方 Open API 演示仍明确描述例句支持“标签和来源标注”。按 Owner 新门槛，#4 已可施工；
- 桌面快速查词仍未实现。

## 3. Current unique next step

```text
ISSUE_4_IMPLEMENTATION_PLAN_AND_OFFLINE_BUILD
```

#4 现在是当前主线。先按现有工程规则为 phrase/example importer 做最小实现设计和离线/假 transport 验证，复用已经成熟的 Preview、fresh preflight、one-POST-max、no retry、authenticated readback、stale authority 和 iOS interruption safety 语义，不借机重构整个产品。

例句产品要求：

- source/origin 必须写入并回读一致；
- tags 在受支持范围内保留，但精确三标签 round-trip / shared discoverability 不阻断；
- English highlight / target range：有 documented reliable path 就实现，没有则明确显示/记录 limitation；
- Chinese translation semantic/character range：有 documented reliable path 就实现，没有则接受缺失，不做 undocumented-field probing；
- Preview 必须让 Owner 看见最终英文句子、中文翻译、来源及将写入的其他受支持字段；
- 写后必须鉴权回读；结果不确定只 GET-only recovery。

当前**只授权产品实现与离线验证**。本状态不授权任何新的真实 phrase POST、Token 使用或主账号写入；真实写入仍需在实现、独立审阅后单独获得明确 Owner 授权。

## 4. Other active routes

### Public launch / distribution

```text
Issue #71 = OPEN / CANDIDATE_ONLY
```

目标是 v0.2 低摩擦分发、仓库 frontage、独立品牌、演示和首批外部用户。当前排在例句线路之后，不是 primary。

### Open Platform authorization research

```text
Issue #72 = OPEN / RESEARCH_CANDIDATE_ONLY
```

只允许在 Owner 后续选择时做 first-party 文档研究；不得因该 Issue 存在而改变现有 manual Token production path。

### Phrase / example automation

```text
Issue #2 = OPEN / SUPPORTING_EVIDENCE_AND_LIMITATIONS
Issue #4 = CURRENT_PRIMARY / IMPLEMENTATION
```

旧的硬阻断标准已被 Owner 2026-08-11 决策放宽：source/origin 可靠写入+回读是当前必须项；tags、English highlight、Chinese translation range 均为尽力实现但非阻断。#2 不再作为 #4 的产品 gate，只保存 API 能力证据、已知限制和后续可选研究。

### Desktop quick lookup

```text
Issue #5 = OPEN / NOT_STARTED
```

仍是独立后续能力，不得自动并入 iOS companion。

### Codex for Open Source

```text
Issue #7 = LONG_TERM_EVIDENCE_BUILDING
```

只积累真实 release、用户、维护、Issue/PR 和安全质量证据，不制造 adoption 信号。

### Superseded legacy issue

```text
Issue #62 = OPEN_BUT_SUPERSEDED_BY_COMPLETED_#63
```

#62 的 Keychain/UX 目标已经由后续 #63 及相关合并实现，不是当前 WIP，也不得因仍 OPEN 自动恢复施工。

## 5. Safety boundaries that remain current

- Preview **不是**授权；任何后续真实写入都必须来自当前有效 Preview 与明确 Owner action；
- mixed batch 对 Owner 可以是一份 whole-plan approval，但内部 CREATE / UPDATE 仍是两个独立 phase，不得把 CREATE approval 当作 UPDATE permission；
- mixed execution 在**第一个 POST 前**对全部 approved items 做 fresh authenticated whole-batch preflight；只有 CREATE phase 完整成功后才进入 UPDATE；UPDATE subset 在任何 UPDATE POST 前再次 fresh preflight 并验证其原始 operation-group binding；
- server state 改变、歧义、credential/source mismatch 或安全检查失败时停止，不扩大旧授权；后续再次尝试必须 fresh Preview；
- 每个 changed item 最多一次 POST；绝不 POST retry；POST 后立即 authenticated GET readback；结果不确定时只做 GET-only recovery；
- 不开放 delete；没有自动 rollback；不修改墨墨内置释义；
- phrase/example 产品路线现已解除旧的 highlight/range/tag 硬阻断，但在实现并完成独立审阅前不得把它视为已验证生产写入路径；任何新的真实 phrase POST 仍需单独明确授权；
- iOS Token 只保存在本设备 Keychain generic-password 项：`kSecAttrAccessibleWhenUnlockedThisDeviceOnly`、不同步；不进入 `UserDefaults`、文件、状态恢复、环境变量、argv、日志、分析、自动剪贴板读取或 URL/query；
- CLI 与 macOS localhost UI 的凭证策略仍按 D-013：隐藏交互输入 / 仅进程内存；D-016 只为 iOS 增加设备本地 Keychain；
- 已开始的 Preview/已授权 execution 可在 iOS 允许的有限后台时间内跨普通切 App/来电继续；系统到期则安全停止；前台返回不得自动 replay/resume、mint 新 approval 或恢复已经失效的 authority；
- Preview 若在后台完成，只能在 source 未变且恢复 credential fingerprint 与 snapshot 一致时恢复；不持久化或复活旧 approval；实际写入仍有执行时 fresh preflight；
- 当前开放 API 没有可靠账号身份端点，Token 实际所属账号仍由操作者确认；
- 换对话、文档更新、Agent 接管或测试 rehearsal **都不构成任何新的真实账号写入授权**。

## 6. Maintenance rule

这个文件应该保持短。只在 current primary Issue、唯一 next step、重要合并 milestone 或当前安全边界发生变化时更新。

若它与实时 Issue/PR/commit 冲突：先以实时远端为准，再机械修正本文件；不要要求 Owner 重讲旧聊天。
