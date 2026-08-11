# momo-moreEfficient Current Project State

status=ACTIVE_LIGHTWEIGHT_PROJECT_STATE
updatedAt=2026-08-11
sourceMainSha=8f1deac64f733c751dca647ed405c5a5e1337047
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
CURRENT_MAIN_AT_SNAPSHOT=8f1deac64f733c751dca647ed405c5a5e1337047
CURRENT_PRODUCT_VERSION=v0.1.0
CURRENT_PRIMARY_ISSUE=#89
CURRENT_UNIQUE_NEXT=ISSUE_89_OFFLINE_IMPLEMENTATION_AND_REVIEW
OPEN_PRODUCT_PR=none
ACTIVE_WIP=none
```

当前已完成：

- `v0.1.0` 释义批量录入闭环、主账号真实 CREATE/UPDATE 与鉴权回读均已验证；
- macOS 本地日常 UI 已验收；iOS companion 已在实体 iPhone 使用；
- iOS Token 按 D-016 保存为仅本设备 Keychain；stale authority、History、有限后台保护和 mixed CREATE→UPDATE 均已完成；
- #82 / PR #83：phrase CREATE-only core 已实现并独立审阅 PASS；
- #84 / PR #85：`释义 | 例句` iPhone UI、独立草稿/authority、phrase Preview / confirmation / CREATE / readback / History、DEBUG rehearsal 已实现、独立审阅、实体 iPhone 11 步 rehearsal PASS，并合入 `main`；
- D-018 已 supersede D-005 的旧 phrase blocker levels：英文/中文/source/`PUBLISHED`/安全唯一 same-English readback 为 hard gate；tags/highlight 为 structurally-valid non-blocking observations；
- #86 已完成第一次真实主账号 phrase production canary：Gate A Preview `新建 1 · 一致 0 · 阻断 0`；Gate B 一次 CREATE 成功，authenticated readback hard gates 全部通过，`MBA/BEC/GMAT` 当前真实 round-trip 成功；
- Owner 在墨墨 App 本体确认英文、中文、source 和三标签均正确可见；Open API readback 未返回 English highlight，但 App 实际视觉上自动高亮英文目标；中文语义位置由 Owner 手工补充；
- #86 已关闭；#2 已降为 supporting evidence，#4 已更新为 phrase 产品总路线；
- #87 已记录 Owner 日常四行纯文本 phrase 输入格式兼容要求；
- #88 已记录当前 `主账号` 是静态 UI 标签，外部用户发布前必须改为 identity-safe account UI；
- 桌面快速查词仍未实现。

## 3. Current unique next step

```text
ISSUE_89_OFFLINE_IMPLEMENTATION_AND_REVIEW
```

#89 是当前主线：让 phrase CREATE 对多例句容量有感知，并为满额场景增加**明确选择目标记录的安全 UPDATE/替换**。

当前产品规则：

- phrase 可有多条 authenticated-user records；
- Owner 从当前 App 实际使用确认每词每用户最多 5 条自建例句；当前 first-party public docs 未找到这个数字，因此 `5` 只作为**Owner-observed、保守产品安全上限**，不得宣称为 documented API constant；
- `<5` 且无 same-English conflict：继续当前 CREATE；
- exact hard-field match：ALREADY_MATCHING / 0 POST；
- `=5` 且是新例句：`REPLACE_REQUIRED`，CREATE 必须 0 POST；用户必须显式选择五条中的一条进行替换；
- `>5`：视为 server/legacy rule mismatch，fail closed；
- 替换使用 first-party documented `POST /phrases/{id}` UPDATE，不采用 delete→create；
- 不得自动选 oldest/first/least-liked 等任何目标；
- phrase UPDATE 首轮只允许 offline/fake/rehearsal 实现和独立审阅，**不授权任何真实 phrase UPDATE**。

UPDATE 仍必须保持：fresh authenticated preflight、目标 record/baseline 精确 binding、每项最多一次 POST、no retry、immediate authenticated GET readback、uncertain outcome GET-only recovery、no delete/rollback/replay。

## 4. Other active routes

### Phrase / example automation

```text
Issue #2 = OPEN / SUPPORTING_EVIDENCE_ONLY
Issue #4 = PARENT_PRODUCT_ROUTE
Issue #87 = FOLLOW_UP / NATIVE_FOUR_LINE_INPUT
Issue #88 = FOLLOW_UP / IDENTITY_SAFE_ACCOUNT_UI
Issue #89 = CURRENT_PRIMARY / CAPACITY_AND_SAFE_REPLACEMENT
```

#87/#88 与 #89 保持独立，避免 parser、account identity 和首次 phrase UPDATE authority 混成一个不可审阅的大改动。

### Public launch / distribution

```text
Issue #71 = OPEN / CANDIDATE_ONLY
```

#88 在外部用户分发前必须解决。

### Open Platform authorization research

```text
Issue #72 = OPEN / RESEARCH_CANDIDATE_ONLY
```

不得自动改变当前 manual Token production path。

### Desktop quick lookup

```text
Issue #5 = OPEN / NOT_STARTED
```

### Codex for Open Source

```text
Issue #7 = LONG_TERM_EVIDENCE_BUILDING
```

只积累真实 release、用户、维护、Issue/PR 和安全质量证据，不制造 adoption 信号。

## 5. Safety boundaries that remain current

- Preview **不是**授权；任何真实写入必须来自当前有效 Preview 与明确 Owner action；
- phrase production 当前只已验证 CREATE；#89 的 UPDATE/replacement 尚未实现、未审阅、未获任何真实运行授权；
- 每个 changed item 最多一次 POST；绝不 POST retry；POST 后立即 authenticated GET readback；结果不确定只做 GET-only recovery；
- server state、source/mode、credential、target record 或 binding 发生变化时停止；再次尝试必须 fresh Preview；
- 不开放 delete；没有自动 rollback / replay；
- phrase tags/highlight 不完整不构成 hard failure，但 malformed/unknown/out-of-bounds response schema 仍 fail closed；source/origin mismatch 始终是 hard failure；
- iOS Token 只在本设备 Keychain generic-password 项，`kSecAttrAccessibleWhenUnlockedThisDeviceOnly`、non-sync；
- current manual Token path 不提供可靠 server-verified Maimemo nickname；当前 `主账号` 只是静态标签，不是身份验证结果；
- 换对话、文档更新、Agent 接管、测试、rehearsal、merge 或此前的 CREATE 授权**都不构成新的 phrase UPDATE 授权**。

## 6. Maintenance rule

只在 current primary Issue、唯一 next step、重要合并 milestone 或当前安全边界变化时更新本文件。不要建立第二套开发编年史或 JSON memory system。
