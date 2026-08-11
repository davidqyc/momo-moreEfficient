# Changelog

本文件只记录已验证的能力和已知限制。不记录计划中的功能，不夸大适用范围。

格式参考 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)，版本号遵循 [语义化版本](https://semver.org/lang/zh-CN/)。

## [Unreleased]

### Added

- 显式的主账号 opt-in：`--allow-main-account`。默认仍为 **false**，不给该开关时导入器的行为与 `v0.1.0` 的副账号/测试账号策略完全一致。参见 [#51](https://github.com/davidqyc/momo-moreEfficient/issues/51) 与 `docs/decision-log.md` 的 D-014。
  - 主账号模式必须**同时**满足两个条件：显式 `--allow-main-account`，以及一个经复核的主账号标签（`主账号` 或 `main-account`）。缺任一条件都会在 Token 提示和网络传输层创建**之前** fail closed。
  - `prod` / `production` 不被当作个人主账号的同义词；`--allow-main-account` 与副账号/测试标签组合同样被拒绝。
  - 独立的隐藏 Token 提示 `Main-account Maimemo Token (hidden):`，以及 preflight 之前的显式警告：当前处于主账号模式、本工具无法可靠校验 Token 归属哪个账号、必须在登录目标主账号的状态下获取 Token、`create` / `update` 会改动真实账号数据。
  - 独立的确认串 `CONFIRM MAIN CREATE <16 位十六进制>` / `CONFIRM MAIN UPDATE <16 位十六进制>`；其摘要覆盖与副账号确认相同的完整绑定，并额外绑定账号模式。副账号确认串无法授权主账号运行，主账号确认串也无法授权副账号运行。
  - 本地脱敏运行报告新增 `account_mode` 字段（`secondary` / `main`）；账号标签本身仍然不落盘。
- 26 个针对主账号 opt-in 的离线测试，总数由 443 增至 469。
- macOS 本地日常 UI（Issue #54）：标准库 localhost 适配层 + 双击 `.app` 启动器，复用现有导入器作为唯一写入安全权威；支持 mixed Preview、分离 CREATE/UPDATE、native hidden Token prompt、fresh preflight、stale-preview 失效和 bounded in-memory credential lifecycle。
- Issue #54 已完成 Owner 真机产品验收：`~/Applications/momo-moreEfficient.app` 双击启动成功且普通使用无 Terminal，真实主账号 12 条批次 Preview 结果为 `新建 0 / 更新 0 / 已一致 12 / 失败 0`，本次 acceptance 未执行写入，渲染内容与预期一致。
- 轻量 iOS companion 已进入 `main` 并完成实体 iPhone 验收：GET-only Preview、CREATE/UPDATE、CURRENT/PROPOSED、fresh preflight、stale-preview 失效与 one-shot native destructive confirmation 均在设备端工作；Token 按 D-016 保存为仅本设备 `WhenUnlockedThisDeviceOnly`、非同步 Keychain 项。
- iPhone 真实主账号写入路径已完成 `sphere` UPDATE canary 与 `incentive` CREATE canary；随后一份真实 mixed 10 条批次完成 CREATE 8/8 + UPDATE 2/2，分别生成 History receipt，最终编辑器清空，10/10 成功。
- iOS 本地 History/receipt 已与活动草稿分离，只保存非敏感执行结果；Token、ID、digest、请求体、响应和释义正文不进入 History。
- 已开始的 Preview 与已授权 execution 现在可在 iOS 允许的有限后台时间内跨普通切 App / 来电继续；系统回收后台时间时安全停止，不自动 replay/resume，也不制造新的 approval。
- mixed actionable batch 的日常 UX 已收口为：一次 Preview → 一次 Run → 一次 native confirmation → 内部 CREATE 后自动 UPDATE。CREATE/UPDATE 仍是两个独立安全 phase；首个 POST 前保留 whole-batch fresh authenticated preflight，CREATE 完整成功后 UPDATE subset 再 fresh preflight。execution-time 安全检查对用户只显示 `安全确认中…`，逐项 `n/N` 只显示真实写入进度。参见 #76 / PR #80。

### Unchanged

- 写入安全模型没有任何放宽：Preview 不是授权；写入前 fresh authenticated validation、每个待写条目最多一次 POST、不重试、写后立即鉴权回读、结果不确定只做 GET-only recovery、失败即停止、不回滚、不删除。
- mixed batch 的一次 whole-plan confirmation **不**合并 CREATE/UPDATE 的内部安全边界：CREATE approval 不作为 UPDATE permission，UPDATE 在任何 POST 前仍需重新验证其原 operation-group binding；server state 改变或歧义时停止。
- CLI 与 macOS localhost UI 的凭证策略继续沿用 D-013：hidden prompt / 仅进程内存；iOS 单独按 D-016 使用仅本设备 Keychain。两条契约不得互相机械套用。
- `scripts/issue9_live_harness.py` 的副账号门禁未放宽，历史 spike/probe 工具仍然只能用于测试账号。
- 仍然没有账号身份接口，因此本工具**不能**证明 Token 属于哪个墨墨账号；账号身份由操作者负责。
- 仍然没有删除路径、没有自动回滚、没有受支持的例句/短语写入产品路径。

### Known limitations

- 从部分聊天/网页渲染直接复制时，源端可能在文本到达本地 UI textarea 前折叠行边界；下载的 text/Markdown 或其他保留换行的来源可正常解析。该现象不作为启用 heuristic parser 的理由。
- iOS companion 已在 Owner 的实体 iPhone 上通过当前日常流程与 DEBUG rehearsal 验收，但尚未提供 TestFlight/App Store 或其它面向陌生用户的低摩擦公开安装路径；v0.2 分发与首次外部用户由 #71 跟踪，尚未自动授权启动。

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
- v0.1.0 CLI 需要交互式终端；非 TTY 环境会被拒绝。后续 `main` 已加入通过真机验收的 macOS 本地日常 UI，普通 UI 使用不要求 Terminal。
- 自动化测试当前只在 **Python 3.13** 上验证（CI 与推荐运行时）。Python 3.9 仅作为遗留兼容性记录，已于 2025-10-31 EOL、不再接收安全更新，不推荐使用；其他版本未经验证。
- v0.1.0 发布时的真实运行验证在副账号完成；后续 `main` 已完成单独评审的真实主账号验证：dry-run 12 条 / 0 POST、CREATE 9/9、UPDATE 3/3，并完成 macOS UI 真实主账号 Preview 验收。

[Unreleased]: https://github.com/davidqyc/momo-moreEfficient/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/davidqyc/momo-moreEfficient/releases/tag/v0.1.0
