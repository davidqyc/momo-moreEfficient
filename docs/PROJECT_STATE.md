# momo-moreEfficient Current Project State

status=ACTIVE_LIGHTWEIGHT_PROJECT_STATE
updatedAt=2026-08-11
sourceMainSha=51a724b6347ac3b8e4085d2bd3eeb3d712c63713
sourceMainShaIsSnapshotOnly=true

## 1. Authority

本文件只保存**当前做到哪、当前唯一下一步和当前边界**。实时 `main`、当前 GitHub Issue/最新评论、PR/commit 和 Owner 最新明确决定始终优先。

```text
长期决定 → docs/decision-log.md
任务合同/验收/阻断 → 当前 GitHub Issue
发布变化 → CHANGELOG.md
长期 API/产品背景 → docs/product-and-api-plan.md
```

若本文件与实时 Issue/PR/commit 冲突，先以实时远端为准，再机械同步本文件；不要让 Owner 重讲旧聊天。

## 2. Current truth

```text
REPOSITORY=davidqyc/momo-moreEfficient
DEFAULT_BRANCH=main
PUBLIC_REPOSITORY=true
CURRENT_MAIN_AT_SNAPSHOT=51a724b6347ac3b8e4085d2bd3eeb3d712c63713
CURRENT_PRODUCT_VERSION=v0.1.0
CURRENT_PRIMARY_ISSUE=#84
CURRENT_UNIQUE_NEXT=ISSUE_84_IMPLEMENTATION_AND_OFFLINE_REHEARSAL_BUILD
OPEN_PRODUCT_PR=none
ACTIVE_WIP=none
```

当前已完成：

- `v0.1.0` 释义批量录入闭环、主账号显式 opt-in、真实 CREATE/UPDATE 与鉴权回读均已验证；
- macOS 本地日常 UI 已验收；
- iOS companion 已在实体 iPhone 使用，Token 按 D-016 保存为仅本设备 Keychain；
- stale Preview、History/receipt、有限后台保护、Preview interruption resilience、one-action mixed CREATE→UPDATE 已完成；
- 真实 10 条 mixed batch 已完成 CREATE 8/8 + UPDATE 2/2；
- #82 / PR #83 已完成并合入 `main`：iOS phrase/example **CREATE-only core** 已实现并独立审阅 PASS，支持严格 `## spelling + EN/ZH/SOURCE` grammar、CREATE / ALREADY_MATCHING / BLOCKED、source/origin hard readback gate、fresh preflight、one-POST-max、no retry、immediate authenticated readback、GET-only uncertain recovery；
- phrase tags / English highlight 只作为结构安全的非阻断 observation；中文 translation range 在 documented API 无写字段时不再阻断；
- #82 Builder/测试和独立审阅均未使用真实 Token、未发真实 Maimemo 请求；
- 桌面快速查词仍未实现。

## 3. Current unique next step

```text
ISSUE_84_IMPLEMENTATION_AND_OFFLINE_REHEARSAL_BUILD
```

#84 是当前主线：把已审阅的 phrase CREATE core 接入现有 iPhone 日常 UI，同时保持现有释义流程零回归。

冻结的产品方向：

- 一个 App，明确 `释义 | 例句` 两种输入模式；默认仍为释义；
- 两种草稿在当前进程内分开保存，切换模式不得复用另一模式的 Preview/approval/suspended authority；
- phrase Preview 只显示 CREATE / ALREADY_MATCHING / BLOCKED，不提供 phrase UPDATE；
- phrase full success 清空 phrase draft；partial/uncertain/interrupted 保留原 phrase draft，下一次必须 fresh Preview；
- `origin`、英文、中文、`PUBLISHED`、安全唯一 same-English readback 是 hard gate；tags/highlight 是非阻断 closed observation；
- phrase 执行进入现有本地 History 时只新增非敏感 content kind，不保存 EN/ZH/SOURCE、tags/highlight、ID、binding、请求或响应；旧 history-v1 必须向后兼容；
- DEBUG rehearsal 必须能在实体 iPhone 上走 phrase Preview → native confirmation → CREATE → readback，且零联网、零真实 Token、零生产 History；
- 完成独立审阅后，下一 gate 是 Owner 实体 iPhone DEBUG rehearsal；通过前不得进行真实 phrase canary。

当前授权只覆盖 **#84 代码实现 + offline/fake/rehearsal 验证**。不授权真实 Token、真实 Maimemo GET/POST、phrase UPDATE/DELETE、release/publish 或未经独立审阅的 merge。

## 4. Other active routes

### Phrase / example automation

```text
Issue #2 = OPEN / SUPPORTING_EVIDENCE_AND_LIMITATIONS
Issue #4 = PARENT_PRODUCT_ROUTE
Issue #84 = CURRENT_PRIMARY / UI_INTEGRATION
```

Owner 于 2026-08-11 明确放宽旧 D-005 阻断标准：source/origin reliable write + readback 是 phrase-specific 必须项；tags、English highlight、Chinese translation range 均为 best-effort/non-blocking。#84 需在其 PR 中追加新的 durable decision，显式 supersede D-005 的旧 blocker levels；不要改写历史。

### Public launch / distribution

```text
Issue #71 = OPEN / CANDIDATE_ONLY
```

排在当前例句线路之后，不是 primary。

### Open Platform authorization research

```text
Issue #72 = OPEN / RESEARCH_CANDIDATE_ONLY
```

不得自动改变当前 manual Token production path。

### Desktop quick lookup

```text
Issue #5 = OPEN / NOT_STARTED
```

独立后续能力。

### Codex for Open Source

```text
Issue #7 = LONG_TERM_EVIDENCE_BUILDING
```

只积累真实 release、用户、维护、Issue/PR 和安全质量证据，不制造 adoption 信号。

### Superseded legacy issue

```text
Issue #62 = OPEN_BUT_SUPERSEDED_BY_COMPLETED_#63
```

不是当前 WIP。

## 5. Safety boundaries that remain current

- Preview **不是**授权；任何真实写入必须来自当前有效 Preview 与明确 Owner action；
- interpretation mixed batch 仍保持 whole-batch fresh preflight、CREATE 完整成功后才进入 UPDATE、UPDATE subset 再 fresh preflight；CREATE approval 不作为 UPDATE permission；
- phrase 当前只允许 CREATE 设计，不存在 phrase UPDATE/DELETE；
- 每个 changed item 最多一次 POST；绝不 POST retry；POST 后立即 authenticated GET readback；结果不确定只做 GET-only recovery；
- server state、source/mode、credential 或 binding 发生变化时停止，不扩大旧授权；再次尝试必须 fresh Preview；
- 不开放 delete；没有自动 rollback / replay；不修改墨墨内置释义；
- phrase 的 tags/highlight 不完整不构成 hard failure，但 malformed/unknown/out-of-bounds response schema 仍 fail closed；source/origin mismatch 始终是 hard failure；
- iOS Token 只在本设备 Keychain generic-password 项，`kSecAttrAccessibleWhenUnlockedThisDeviceOnly`、non-sync；不进入 `UserDefaults`、文件、状态恢复、argv、环境变量、日志、分析、自动剪贴板读取或 URL/query；
- CLI/macOS localhost UI 凭证契约仍按 D-013；
- 已开始的 Preview/已授权 execution 只可在 iOS 允许的有限后台时间内继续；系统到期安全停止；前台返回不得 replay/resume、mint 新 approval 或恢复失效 authority；
- 当前开放 API 没有可靠 account identity endpoint，Token 实际所属账号仍由操作者确认；
- 换对话、文档更新、Agent 接管、测试或 rehearsal **都不构成新的真实账号写入授权**。

## 6. Maintenance rule

只在 current primary Issue、唯一 next step、重要合并 milestone 或当前安全边界变化时更新本文件。不要建立第二套开发编年史或 JSON memory system。
