# Changelog

本文件只记录已验证的能力和已知限制。不记录计划中的功能，不夸大适用范围。

格式参考 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)，版本号遵循 [语义化版本](https://semver.org/lang/zh-CN/)。

## [Unreleased]

暂无。

## [0.1.0] - 未发布（准备中）

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
- 最小 GitHub Actions 工作流：无密钥、无网络、运行完整离线测试套件。

### Security

- 真实 Token **只**通过隐藏交互式 `getpass` 输入，仅存于进程内存。不支持命令行参数、环境变量、`.env`、配置文件、剪贴板或系统钥匙串。
- Token、`Authorization`、Cookie、账号标签、原始 `voc_id`、原始记录 ID 和原始服务器响应，都不会进入预览、日志、运行报告或 Git。
- 每个待写条目最多一次 POST，任何情况下都不重试；POST 结果未知时只做一次内置 GET 恢复查询。
- 更新目标记录 ID 只来自鉴权 GET 集合，不接受来自命令行或 Markdown 的记录 ID。
- 只使用 `GET` 和 `POST`；没有 `PUT` / `PATCH` / `DELETE` 路径，也没有例句/短语请求路径。
- 请求串行发出、无并发，最小间隔 1.6 秒，对齐官方公布的频控。
- 中途失败即停止剩余条目；不回滚、不删除，并明确提示不要重发。
- 不修改墨墨内置词典释义。

### Known limitations

- **例句/短语自动化不可用**，且被刻意阻断：真实验证显示例句创建后鉴权回读拿不到完整的 `MBA` + `BEC` + `GMAT` 标签集，`highlight` 缺失，公开 CREATE 契约也没有可写的 highlight 字段。参见 [#2](https://github.com/davidqyc/momo-moreEfficient/issues/2)、[#4](https://github.com/davidqyc/momo-moreEfficient/issues/4)。
- **桌面快速查词未实现**，属于未来工作。参见 [#5](https://github.com/davidqyc/momo-moreEfficient/issues/5)。
- 没有自动回滚：被替换的释义只能依据本地脱敏报告中的写前快照人工恢复。
- 没有跨账号标签发现能力——公开 API 未提供该端点。
- 没有账号身份接口，因此 `--account-label` 只能防止人工过程中拿错凭证，不能证明 Token 属于哪个账号。
- 单批上限 30 条（典型 8–15 条）。
- 需要交互式终端；非 TTY 环境会被拒绝。
- 自动化测试当前只在 Python 3.9 上验证。
- 真实运行验证均在副账号完成，批次规模为最小的 3 条；主账号接入需要单独评审。

[Unreleased]: https://github.com/davidqyc/momo-moreEfficient/compare/main...HEAD
[0.1.0]: https://github.com/davidqyc/momo-moreEfficient
