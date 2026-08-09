# momo-moreEfficient Current Project State

status=ACTIVE_LIGHTWEIGHT_PROJECT_STATE
updatedAt=2026-08-09
sourceMainSha=8d5112ad3ce2185f34c7759e302d17bb5a1515dc
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
CURRENT_MAIN_AT_SNAPSHOT=8d5112ad3ce2185f34c7759e302d17bb5a1515dc
CURRENT_PRODUCT_VERSION=v0.1.0
CURRENT_PRIMARY_ISSUE=#54
OPEN_PRODUCT_PR=none at snapshot
```

当前已完成：

- `v0.1.0` 的核心释义批量录入闭环已经成立：`dry-run / create / update`；
- 副账号 create / update / immediate readback 的真实端到端验证已经完成；
- 仓库已经公开，v0.1.0 release markers 已完成；
- Issue #51 的**显式主账号 opt-in** 实现已经通过独立 PASS 并合入 `main`；
- Issue #51 的真实主账号闭环已经完成：dry-run 12 条 / 0 POST、CREATE 9/9、UPDATE 3/3，Owner 在 App 侧复核显示正确；
- D-014 已进入 `docs/decision-log.md`：主账号必须显式 `--allow-main-account`，并保持 fail-closed 账号标签和原有写入安全模型；
- `scripts/issue9_live_harness.py` 仍保持副账号/测试账号专用，未被主账号路径放宽。

## 3. Current unique next step

```text
ISSUE_54_BUILD_AND_REVIEW_DAILY_LOCAL_UI
```

Issue #51 已完成并关闭。当前唯一下一步是实现、离线验证和审阅 Issue #54 的日常本地 UI：使用 Python 标准库 localhost 适配层和 macOS 双击启动器，保持既有导入器为唯一写入安全权威。该实现 Issue 不读取真实 Token、不发送真实墨墨请求，也不执行真实主账号批次。

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

仍是后续独立能力，不得抢在当前主账号释义录入闭环之前扩大技术栈。

### Codex for Open Source

```text
Issue #7 = LONG_TERM_EVIDENCE_BUILDING
```

只积累真实 release、用户、维护、Issue/PR 和安全质量证据，不制造 adoption 信号。

## 5. Safety boundaries that remain current

- Token 只通过隐藏交互式 `getpass` 输入，memory-only；不从 argv/env/.env/config/clipboard/Keychain 读取；
- 主账号模式必须显式 `--allow-main-account` + 经复核的主账号标签；
- 当前 API 无账号身份端点，Token 实际所属账号仍由操作者负责确认；
- 不开放 delete；没有自动 rollback；
- update 只针对唯一明确的用户自建记录；歧义时停止；
- whole-batch preflight、exact preview、one POST per changed item、no POST retry、immediate readback 保持；
- 不修改墨墨内置释义；
- phrase/example automation 仍 blocked；
- 真实写入不得因为换对话、文档更新或新 Agent 接管而自动授权。

## 6. Maintenance rule

这个文件应该保持短。只在 current primary Issue、唯一 next step、重要合并 milestone 或当前安全边界发生变化时更新。

若它与实时 Issue/PR/commit 冲突：先以实时远端为准，再机械修正本文件；不要要求 Owner 重讲旧聊天。
