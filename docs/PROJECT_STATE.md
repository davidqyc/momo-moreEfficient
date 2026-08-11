# momo-moreEfficient Current Project State

status=ACTIVE_LIGHTWEIGHT_PROJECT_STATE
updatedAt=2026-08-11
sourceMainSha=6977c9f385bdda7beb2cd49e57d06608fadf690e
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
CURRENT_MAIN_AT_SNAPSHOT=6977c9f385bdda7beb2cd49e57d06608fadf690e
CURRENT_PRODUCT_VERSION=v0.1.0
CURRENT_PRIMARY_ISSUE=#86
CURRENT_UNIQUE_NEXT=WAIT_FOR_OWNER_GATE_B_ONE_POST_AUTHORIZATION
OPEN_PRODUCT_PR=none
ACTIVE_WIP=none
```

当前已完成：

- `v0.1.0` 释义批量录入闭环、主账号显式 opt-in、真实 CREATE/UPDATE 与鉴权回读均已验证；
- macOS 本地日常 UI 已验收；
- iOS companion 已在实体 iPhone 使用，Token 按 D-016 保存为仅本设备 Keychain；
- stale Preview、History/receipt、有限后台保护、Preview interruption resilience、one-action mixed CREATE→UPDATE 已完成；
- 真实 10 条 interpretation mixed batch 已完成 CREATE 8/8 + UPDATE 2/2；
- #82 / PR #83 已完成并合入：iOS phrase/example CREATE-only core 已实现并独立审阅 PASS；
- #84 / PR #85 已完成并合入 `main`：单 App `释义 | 例句` 模式、独立草稿/authority、phrase Preview / native confirmation / CREATE / readback / History、DEBUG rehearsal 均已完成；
- PR #85 在一次 CHANGES REQUIRED 后完成窄修复并通过 delta re-review；
- Owner 已在实体 iPhone 对 PR #85 精确 head 完成 11 步 DEBUG rehearsal，全部符合预期：CREATE 3、后台切 App 后继续、History、草稿清空、第二次 ALREADY_MATCHING 3、释义草稿隔离均通过；该 rehearsal 零真实 Token、零 Maimemo 网络、零 production History；
- D-018 已显式 supersede D-005 的旧 phrase blocker levels：`origin` / 英文 / 中文 / `PUBLISHED` / 安全唯一 same-English readback 为 hard gate；tags/highlight 为 structurally-valid non-blocking observations；中文 range 在 documented API 无写字段时可 unavailable；
- #85 已 squash merge 为 `6977c9f385bdda7beb2cd49e57d06608fadf690e`，#84 自动关闭；
- #86 的真实单条 phrase canary 已由 Owner 提供精确内容并授权 Gate A；实体 iPhone production Preview 已真实 GET-only 完成，结果为 `新建 1 · 一致 0 · 阻断 0`；尚未发生 phrase POST；
- #87 已记录 Owner 日常四行纯文本 phrase 输入格式兼容要求；当前生产 phrase parser 仍只接受严格 labeled grammar；
- #88 已记录当前 iOS `主账号` 为静态 UI 标签、不是 server-verified identity；在缺少 documented account identity endpoint 时，外部用户版本必须改成 identity-safe 中性文案或明确的本地标签；
- 桌面快速查词仍未实现。

## 3. Current unique next step

```text
WAIT_FOR_OWNER_GATE_B_ONE_POST_AUTHORIZATION
```

#86 是当前唯一主线：第一次真实 phrase production canary，固定为 **1 条 Owner 真正想保留的主账号例句**。

Gate A 已完成：Owner 已独立确认目标主账号，并在 production iPhone App 中对精确 canary 内容执行真实 authenticated GET-only Preview，结果为：

```text
新建 1 · 一致 0 · 阻断 0
```

当前只剩 **Gate B — one real CREATE POST**。必须由 Owner 再次明确授权后，才可在当前有效 Preview 上点击原生 destructive confirmation 执行。执行时仍必须：

- fresh authenticated preflight before POST；
- 最多一次 POST；
- no POST retry；
- dispatched POST 后立即 authenticated GET readback；
- uncertain outcome 只允许 GET-only recovery；
- no UPDATE / DELETE / rollback / replay。

当前状态：

```text
CANARY_CONTENT=LOCKED_TO_OWNER_SUPPLIED_ONE_ITEM
REAL_PHRASE_GET_AUTHORIZATION=GRANTED_AND_COMPLETED
GATE_A_RESULT=CREATE_1_MATCHING_0_BLOCKED_0
REAL_PHRASE_POST_AUTHORIZATION=NOT_YET_GRANTED
```

不得把 Owner 的“继续”、merge 授权、Issue 创建、之前的 DEBUG rehearsal、Gate A 授权或任何文档状态解释成 Gate B 的真实 POST 授权。

## 4. Other active routes

### Phrase / example automation

```text
Issue #2 = OPEN / SUPPORTING_EVIDENCE_AND_LIMITATIONS
Issue #4 = PARENT_PRODUCT_ROUTE
Issue #86 = CURRENT_PRIMARY / ONE_ITEM_REAL_CANARY
Issue #87 = FOLLOW_UP / NATIVE_FOUR_LINE_INPUT
Issue #88 = FOLLOW_UP / IDENTITY_SAFE_ACCOUNT_UI
```

#82/#84 已完成；#86 只验证第一次 production CREATE runtime path。若一条 canary 的 hard readback + Owner App-level 检查都通过，再单独决定是否扩大到普通 phrase batch。#87/#88 不在 canary 前插入实现，以免混入新的 parser/UI 变量。

### Public launch / distribution

```text
Issue #71 = OPEN / CANDIDATE_ONLY
```

排在当前 canary 之后，不是 primary。#88 在外部用户分发前必须解决。

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
- phrase 当前只允许 CREATE，不存在 phrase UPDATE/DELETE；
- #86 的真实 canary 固定为一条，并把 GET-only Preview 与 POST write 拆成两个 Owner gate；
- 每个 changed item 最多一次 POST；绝不 POST retry；POST 后立即 authenticated GET readback；结果不确定只做 GET-only recovery；
- server state、source/mode、credential 或 binding 发生变化时停止，不扩大旧授权；再次尝试必须 fresh Preview；
- 不开放 delete；没有自动 rollback / replay；不修改墨墨内置释义；
- phrase 的 tags/highlight 不完整不构成 hard failure，但 malformed/unknown/out-of-bounds response schema 仍 fail closed；source/origin mismatch 始终是 hard failure；
- iOS Token 只在本设备 Keychain generic-password 项，`kSecAttrAccessibleWhenUnlockedThisDeviceOnly`、non-sync；不进入 `UserDefaults`、文件、状态恢复、argv、环境变量、日志、分析、自动剪贴板读取或 URL/query；
- CLI/macOS localhost UI 凭证契约仍按 D-013；
- 已开始的 Preview/已授权 execution 只可在 iOS 允许的有限后台时间内继续；系统到期安全停止；前台返回不得 replay/resume、mint 新 approval 或恢复失效 authority；
- 当前 documented Open API 没有可靠 account identity endpoint，Token 实际所属账号仍由操作者确认；当前 iOS `主账号` 只是静态标签，不是身份验证结果；
- 换对话、文档更新、Agent 接管、测试、rehearsal、merge、Gate A 或“继续”**都不构成新的真实 POST 授权**。

## 6. Maintenance rule

只在 current primary Issue、唯一 next step、重要合并 milestone 或当前安全边界变化时更新本文件。不要建立第二套开发编年史或 JSON memory system。
