# Changelog

本文件只记录已验证的能力和已知限制。不记录计划中的功能，不夸大适用范围。

格式参考 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)，版本号遵循 [语义化版本](https://semver.org/lang/zh-CN/)。

## [Unreleased]

暂无。

## [0.1.0] - 2026-08-09

第一个可用版本，范围刻意收窄为**释义批量录入**这一条已验证闭环。

### Added

- 小批量自建释义导入器 `scripts/interpretation_batch_importer.py`，支持三种模式：
  - `dry-run`：解析、解析词条、preflight 预览；每条 2 个 GET，0 个 POST；
  - `create`：为当前没有自建释义的词创建新的自建释义；
  - `update`：替换当前登录账号自己创建的那一条自建释义。
- 单一 Markdown 批次格式（`## <spelling>` + 释义正文），释义正文按字节保留，不做任何改写。
- 固定标签 `MBA` / `BEC` / `GMAT` 与固定状态 `PUBLISHED`，均由项目固定，不接受命令行传入。
- 完整批级 preflight 与判定：`READY_CREATE`、`READY_UPDATE`、`ALREADY_MATCHING`、`BLOCK_EXISTING`、`BLOCK_MISSING`、`BLOCK_AMBIGUOUS`、`BLOCK_ERROR`。
- 一次批级确认门禁，绑定 operation、host、path、账号标签、Token 指纹、批次 digest、每条拼写与精确释义、标签、状态和条目数；`update` 使用 31 字符短令牌 `CONFIRM UPDATE <16 位十六进制>`，其摘要覆盖同一份完整绑定。
- 写后立即鉴权 GET 回读，逐字段核对正文、三标签集与状态。
- 被 Git 忽略的本地脱敏运行报告（`artifacts/private/`），包含 update 的写前快照以支持**人工**恢复。
- 副账号标签护栏：标签必须包含 `secondary` / `test` / `副号` / `副账号` / `测试`，且拒绝 `main` / `primary` / `owner` / `prod` / `production` / `主号` / `主账号` / `主账户` / `生产`。
- 443 个自动化测试，全部在进程级 no-network guard 下离线运行。
- 合成示例批次 `examples/sample-batch.md`。
- 最小 GitHub Actions 工作流：单 job、无密钥、无网络，在 **Python 3.13** 上运行完整离线测试套件。

### Security

- 真实 Token **只**通过隐藏交互式 `getpass` 输入，仅存于进程内存。不支持命令行参数、环境变量、`.env`、配置文件、剪贴板或系统钥匙串。
- Token、`Authorization`、Cookie、账号标签、原始 `voc_id`、原始记录 ID 和原始服务器响应，都不会进入预览、日志、运行报告或 Git。
- 每个待写条目最多一次 POST，任何情况下都不重试；POST 结果未知时只做一次内置 GET 恢复查询。
- 更新目标记录 ID 只来自鉴权 GET 集合，不接受来自命令行或 Markdown 的记录 ID。
- 受支持的导入器 `scripts/interpretation_batch_importer.py` 只使用 `GET` 和 `POST`；没有 `PUT` / `PATCH` / `DELETE` 路径，且只发出经过复核的词汇/释义请求，其中不含任何例句/短语请求路径。（该表述的范围是这一个受支持命令，不是整个仓库；仓库仍保留历史探针脚本，见 Known limitations。）
- 请求串行发出、无并发，最小间隔 1.6 秒，对齐官方公布的频控。
- 中途失败即停止剩余条目；不回滚、不删除，并明确提示不要重发。
- 不修改墨墨内置词典释义。

### Known limitations

- **例句/短语自动化不可用**，且被刻意阻断：真实验证显示例句创建后鉴权回读拿不到完整的 `MBA` + `BEC` + `GMAT` 标签集，`highlight` 缺失，公开 CREATE 契约也没有可写的 highlight 字段。参见 [#2](https://github.com/davidqyc/momo-moreEfficient/issues/2)、[#4](https://github.com/davidqyc/momo-moreEfficient/issues/4)。
- 仓库仍保留开发期的历史 API 探针/诊断脚本（`scripts/phrase_create_probe.py`、`scripts/phrase_readback_diagnostic.py`、`scripts/issue2_smoke.py`、冻结的 `scripts/issue9_live_harness.py`）。它们是 **内部 / 非受支持** 的开发工具，**不属于 v0.1.0 产品接口**；其中例句探针 CLI 具备真实联网能力并会请求 `/open/api/v1/phrases`，普通用户不应运行，更不应针对生产账号运行。保留只为不丢失工程验证历史，例句自动化本身仍被阻断。
- **桌面快速查词未实现**，属于未来工作。参见 [#5](https://github.com/davidqyc/momo-moreEfficient/issues/5)。
- 没有自动回滚：被替换的释义只能依据本地脱敏报告中的写前快照人工恢复。
- 没有跨账号标签发现能力——公开 API 未提供该端点。
- 没有账号身份接口，因此 `--account-label` 只能防止人工过程中拿错凭证，不能证明 Token 属于哪个账号。
- 单批上限 30 条（典型 8–15 条）。
- 需要交互式终端；非 TTY 环境会被拒绝。
- 自动化测试当前只在 **Python 3.13** 上验证（CI 与推荐运行时）。Python 3.9 仅作为遗留兼容性记录，已于 2025-10-31 EOL、不再接收安全更新，不推荐使用；其他版本未经验证。
- 真实运行验证均在副账号完成，批次规模为最小的 3 条；主账号接入需要单独评审。

[Unreleased]: https://github.com/davidqyc/momo-moreEfficient/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/davidqyc/momo-moreEfficient/releases/tag/v0.1.0
