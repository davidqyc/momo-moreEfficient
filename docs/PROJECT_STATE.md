# momo-moreEfficient Current Project State

status=ACTIVE_LIGHTWEIGHT_PROJECT_STATE
updatedAt=2026-08-10
sourceMainSha=8c93a25fff4351293e73a6bf066ab91ad1b15db9
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
CURRENT_MAIN_AT_SNAPSHOT=8c93a25fff4351293e73a6bf066ab91ad1b15db9
CURRENT_PRODUCT_VERSION=v0.1.0
CURRENT_PRIMARY_ISSUE=#66
OPEN_PRODUCT_PR=#66 implementation pending Draft PR at state update
```

当前已完成：

- `v0.1.0` 的核心释义批量录入闭环已经成立：`dry-run / create / update`；
- 副账号 create / update / immediate readback 的真实端到端验证已经完成；
- Issue #51 的显式主账号 opt-in 与真实主账号闭环已经完成：dry-run 12 条 / 0 POST、CREATE 9/9、UPDATE 3/3；
- Issue #54 的 macOS 本地日常 UI 已合并并完成 Owner 真机验收：`.app` 双击启动、native hidden Token prompt、真实主账号 12 条 Preview，结果 `新建 0 / 更新 0 / 已一致 12 / 失败 0`，本次 acceptance 无写入；
- 当前 macOS UI 的直接聊天复制可能先于解析器丢失行边界，这是非阻断 UX 观察；#54 已关闭，不在该 Issue 内扩成 heuristic parser；
- Issue #56 的轻量 iOS companion 已完成实现、独立审阅、真机安装与真实主账号 Preview 验收；首个真实 iPhone Preview 结果为 `CREATE 0 / UPDATE 0 / ALREADY_MATCHING 12 / BLOCKED 0 / POST 0`，#56 已关闭；
- Issue #60 的真实 12 条 Preview 已观察到 `CREATE 9 / UPDATE 3`，没有点击执行按钮，也没有写入授权；
- Issue #63 的紧凑 iOS 日常界面和仅本设备 Keychain Token 持久化已经完成、合并并经真机确认；
- Issue #66 是临时 UX/assets 修复门槛：后台保留只读 stale Preview 展示、清除全部执行授权，并加入暂定 AppIcon；
- phrase/example automation 仍保持 blocked；桌面快速查词仍未实现。

## 3. Current unique next step

```text
ISSUE_66_STALE_PREVIEW_APPICON_REPAIR_GATE
```

Issue #66 是当前临时修复门槛：后台只保留进程内只读 Preview 展示，清除快照、session、确认与一次性 approval 等全部执行授权，并加入 Owner 选定的暂定 AppIcon。

Issue #60 保持 OPEN 但暂停。#66 经独立审阅、合并并安装后，必须从新的真实 Preview 恢复；此前观察到的 `CREATE 9 / UPDATE 3` 只是证据，不构成写入授权，任何旧授权均不得跨越本次修复。

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
- iOS Token 只保存为本设备 Keychain generic-password 项，使用 `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` 且不同步；不进入 `UserDefaults`、文件、状态恢复、环境变量、argv、日志、分析、自动剪贴板读取或 URL/query；
- iOS 进入 inactive/background 会取消未派发操作、清除瞬态 session credential、session ID、可执行 PreviewSnapshot、确认与 approval，但不删除 Keychain Token；已完成的 PreviewPresentation 只可作为进程内 stale/read-only 展示保留，前台解锁后恢复连接本身不能恢复执行授权；
- iOS production networking 使用 ephemeral URLSession、ATS 默认安全策略和关闭的 reviewed host/path；
- iOS Preview 不是授权；任何输入、credential、background 或既有执行变化都会使其失效，写入前必须 fresh preflight 并与原 preview binding 精确一致；
- iOS destructive confirmation 是绑定当前 preview / operation group / session 的一次性结构门禁；
- 当前 API 无账号身份端点，Token 实际所属账号仍由操作者负责确认；
- 不开放 delete；没有自动 rollback；
- update 只针对唯一明确的用户自建记录；歧义时停止；
- 不修改墨墨内置释义；phrase/example automation 仍 blocked；
- Issue #60 在 #66 合并、安装和 fresh Preview 前保持暂停；恢复后首个真实 iPhone 写入仍只允许一个 genuine item、一个 operation group，并需新的精确 Owner 授权；
- 真实写入不得因为换对话、文档更新或新 Agent 接管而自动授权。

## 6. Maintenance rule

这个文件应该保持短。只在 current primary Issue、唯一 next step、重要合并 milestone 或当前安全边界发生变化时更新。

若它与实时 Issue/PR/commit 冲突：先以实时远端为准，再机械修正本文件；不要要求 Owner 重讲旧聊天。
