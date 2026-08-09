# momo-moreEfficient Current Project State

status=ACTIVE_LIGHTWEIGHT_PROJECT_STATE
updatedAt=2026-08-09
sourceMainSha=9336a00fa6b9c1c35fd1dd74261b90e91e07bcfe
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
CURRENT_MAIN_AT_SNAPSHOT=9336a00fa6b9c1c35fd1dd74261b90e91e07bcfe
CURRENT_PRODUCT_VERSION=v0.1.0
CURRENT_PRIMARY_ISSUE=#60
OPEN_PRODUCT_PR=none at state update
```

当前已完成：

- `v0.1.0` 的核心释义批量录入闭环已经成立：`dry-run / create / update`；
- 副账号 create / update / immediate readback 的真实端到端验证已经完成；
- Issue #51 的显式主账号 opt-in 与真实主账号闭环已经完成：dry-run 12 条 / 0 POST、CREATE 9/9、UPDATE 3/3；
- Issue #54 的 macOS 本地日常 UI 已合并并完成 Owner 真机验收：`.app` 双击启动、native hidden Token prompt、真实主账号 12 条 Preview，结果 `新建 0 / 更新 0 / 已一致 12 / 失败 0`，本次 acceptance 无写入；
- 当前 macOS UI 的直接聊天复制可能先于解析器丢失行边界，这是非阻断 UX 观察；#54 已关闭，不在该 Issue 内扩成 heuristic parser；
- Issue #56 的轻量 iOS companion 已完成实现、独立审阅、真机安装与真实主账号 Preview 验收；首个真实 iPhone Preview 结果为 `CREATE 0 / UPDATE 0 / ALREADY_MATCHING 12 / BLOCKED 0 / POST 0`，#56 已关闭；
- iOS v1 Token 仍为 `SecureField` + process/session memory-only，不使用 Keychain/UserDefaults/文件/自动剪贴板读取；
- phrase/example automation 仍保持 blocked；桌面快速查词仍未实现。

## 3. Current unique next step

```text
ISSUE_60_FIRST_REAL_IPHONE_INTERPRETATION_WRITE_VALIDATION
```

Issue #60 是当前唯一主线：使用 Owner **确实想录入或更新**的一条释义，在实体 iPhone 上先做真实 Preview，再根据该 Preview 单独获得针对**精确 operation group + item count** 的明确 Owner 写入授权，最后验证一次 iOS CREATE 或 UPDATE 的真实 POST + immediate readback + 墨墨 App 人工复核。

不得为了测试而制造无意义主账号数据。若 Owner 当前没有真实待录入/待更新项，就等待，不用 synthetic word 污染账号。

Issue #60 本身不自动授权 POST。真实写入必须在 Preview 完成且结果符合预期后，由 Owner 再次明确授权；此前任何“继续”都不能跨过这个门。

## 4. Other active routes

### Phrase / example automation

```text
Issue #2 = OPEN
Issue #4 = BLOCKED_BY_ISSUE_2
```

当前 phrase 路线仍因 tag round-trip / discoverability、English highlight、中文位置能力等阻断。不要因为释义线路已经成功就自动重开 phrase importer。

### Desktop quick lookup

```text
Issue #5 = OPEN / NOT_STARTED
```

仍是后续独立能力，不得自动并入 iOS companion。

### Codex for Open Source

```text
Issue #7 = LONG_TERM_EVIDENCE_BUILDING
```

只积累真实 release、用户、维护、Issue/PR 和安全质量证据，不制造 adoption 信号。

## 5. Safety boundaries that remain current

- 现有 CLI 主账号模式仍保持显式 opt-in、整批 preflight、exact preview、one POST per changed item、no POST retry、immediate readback；
- macOS UI 的主账号 Token 只在本地 UI 进程内存中存在，通过 native hidden prompt 输入，不进入浏览器持久存储、日志或 Git；
- iOS v1 Token 仍为 `SecureField` 输入 + process/session memory-only：不使用 Keychain/UserDefaults/文件/自动剪贴板读取，进入 background 即使 credential 与 preview 失效；
- iOS production networking 使用 ephemeral URLSession、ATS 默认安全策略和关闭的 reviewed host/path；
- iOS Preview 不是授权；任何输入、credential、background 或既有执行变化都会使其失效，写入前必须 fresh preflight 并与原 preview binding 精确一致；
- iOS destructive confirmation 是绑定当前 preview / operation group / session 的一次性结构门禁；
- 当前 API 无账号身份端点，Token 实际所属账号仍由操作者负责确认；
- 不开放 delete；没有自动 rollback；
- update 只针对唯一明确的用户自建记录；歧义时停止；
- 不修改墨墨内置释义；phrase/example automation 仍 blocked；
- Issue #60 的首个真实 iPhone 写入只允许一个 genuine item、一个 operation group；Preview 后仍需新的精确 Owner 授权；
- 真实写入不得因为换对话、文档更新或新 Agent 接管而自动授权。

## 6. Maintenance rule

这个文件应该保持短。只在 current primary Issue、唯一 next step、重要合并 milestone 或当前安全边界发生变化时更新。

若它与实时 Issue/PR/commit 冲突：先以实时远端为准，再机械修正本文件；不要要求 Owner 重讲旧聊天。
