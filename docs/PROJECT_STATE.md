# momo-moreEfficient Current Project State

status=ACTIVE_LIGHTWEIGHT_PROJECT_STATE
updatedAt=2026-08-10
sourceMainSha=265e09c9c54f0210f2a13f02927cf1fb506be025
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
CURRENT_MAIN_AT_SNAPSHOT=265e09c9c54f0210f2a13f02927cf1fb506be025
CURRENT_PRODUCT_VERSION=v0.1.0
CURRENT_PRIMARY_ISSUE=#69
OPEN_PRODUCT_PR=#69 implementation pending Draft PR at state update
```

当前已完成：

- `v0.1.0` 的核心释义批量录入闭环已经成立：`dry-run / create / update`；
- 副账号 create / update / immediate readback 的真实端到端验证已经完成；
- Issue #51 的显式主账号 opt-in 与真实主账号闭环已经完成：dry-run 12 条 / 0 POST、CREATE 9/9、UPDATE 3/3；
- Issue #54 的 macOS 本地日常 UI 已合并并完成 Owner 真机验收：`.app` 双击启动、native hidden Token prompt、真实主账号 12 条 Preview，结果 `新建 0 / 更新 0 / 已一致 12 / 失败 0`，本次 acceptance 无写入；
- 当前 macOS UI 的直接聊天复制可能先于解析器丢失行边界，这是非阻断 UX 观察；#54 已关闭，不在该 Issue 内扩成 heuristic parser；
- Issue #56 的轻量 iOS companion 已完成实现、独立审阅、真机安装与真实主账号 Preview 验收；首个真实 iPhone Preview 结果为 `CREATE 0 / UPDATE 0 / ALREADY_MATCHING 12 / BLOCKED 0 / POST 0`，#56 已关闭；
- Issue #60 的单条 `sphere` UPDATE canary 已完成真实写入与鉴权回读；
- Issue #68 的单条 `incentive` CREATE canary 已完成真实写入与鉴权回读；
- Issue #63 的紧凑 iOS 日常界面和仅本设备 Keychain Token 持久化已经完成、合并并经真机确认；
- Issue #66 的 stale Preview 与 AppIcon 修复已经合并并安装；
- Issue #69 是当前 UX/history 门槛：将不可变执行回执与新草稿分离，并加入仅本设备的非敏感执行历史；
- phrase/example automation 仍保持 blocked；桌面快速查词仍未实现。

## 3. Current unique next step

```text
ISSUE_69_EXECUTION_RECEIPT_HISTORY_GATE
```

Issue #69 是当前唯一实施门槛：成功执行后把不可变、非敏感回执归档到本地 History，并让活动工作流回到干净草稿；部分、失败或停止时保留原草稿供检查和恢复。

剩余 genuine batch 在 #69 完成审阅、合并和真机安装前继续等待。既有 `sphere` / `incentive` canary 不回填 History，也不构成任何后续批次授权。

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
- 剩余真实批次在 #69 审阅、合并和安装前保持暂停；之后任何真实 iPhone 写入仍需新的 Preview、原生确认和精确 Owner 授权；
- 真实写入不得因为换对话、文档更新或新 Agent 接管而自动授权。

## 6. Maintenance rule

这个文件应该保持短。只在 current primary Issue、唯一 next step、重要合并 milestone 或当前安全边界发生变化时更新。

若它与实时 Issue/PR/commit 冲突：先以实时远端为准，再机械修正本文件；不要要求 Owner 重讲旧聊天。
