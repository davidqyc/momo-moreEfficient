# momo-moreEfficient

一个基于墨墨开放 API 的**非官方效率增强工具**，目标是减少批量录入自建释义时的重复操作。

An unofficial Maimemo companion for safer batch publishing of user-curated vocabulary interpretations.

> **当前状态：v0.1.0 发布准备中。** 释义批量录入闭环（`dry-run` / `create` / `update`）已经在副账号上完成真实端到端验证，是本版本唯一支持的能力。例句/短语自动化仍被阻断，桌面快速查词尚未开始实现。

## v0.1.0 支持什么

只有一件事，而且这件事是可用的：**把一批已经写好的自建释义安全地录入墨墨**。

- 解析一种 Markdown 批次格式；
- `dry-run` 预览每个词的判定结果，不发出任何写请求；
- `create` 新建自建释义；
- `update` 替换**当前登录账号自己创建的那一条**自建释义；
- 固定标签 `MBA` `BEC` `GMAT`，固定状态 `PUBLISHED`；
- 每个待写条目最多一次 POST，**不重试**，写后立即鉴权回读核对；
- 在本地被 Git 忽略的目录写一份脱敏运行报告。

本工具**不会**改写、润色、翻译或总结你准备好的释义正文。唯一的文本处理是把文档自身的换行/空行边界规范化，以便切分条目。

### v0.1.0 不支持什么

- **例句/短语自动化**：不支持，且被刻意阻断。真实验证发现例句创建后，鉴权回读拿不到完整的 `MBA` + `BEC` + `GMAT` 标签集，且 `highlight`（英文目标词位置）缺失，公开 CREATE 契约也没有可写的 highlight 字段。在这些语义位置要求解决前发布例句自动化，会静默产出标注错误的例句。详见 [#2](https://github.com/davidqyc/momo-moreEfficient/issues/2) 和 [#4](https://github.com/davidqyc/momo-moreEfficient/issues/4)。
- **桌面快速查词**：属于未来工作，**尚未实现、未随本版本发布**。详见 [#5](https://github.com/davidqyc/momo-moreEfficient/issues/5)。
- 删除能力、自动回滚引擎、GUI、数据库、服务端、通用 Maimemo 客户端库：都不在范围内。

## 环境要求

- **Python 3.9，仅标准库**。没有第三方依赖，没有安装步骤，不需要虚拟环境。
- 一个墨墨开放 API Token。**请使用副账号 / 测试账号**，不要使用主账号。
- 一个交互式终端（工具会拒绝在非 TTY 环境下运行）。

自动化测试当前验证于 Python 3.9；更新的 Python 版本很可能可用，但尚未验证。

## 输入格式

一种格式，只有一种。`## ` 开头的二级标题是单词拼写，标题之后直到下一个 `## ` 之间的全部内容是该词的释义正文：

```markdown
## <spelling>
<interpretation body>
```

完整示例（合成示例，非任何人的真实学习数据）：

```markdown
## amortization
n. 摊销；分期偿还

## covenant
n. 契约条款；（贷款协议中的）限制性条款

## liquidity
n. 流动性；变现能力
```

仓库中的 [`examples/sample-batch.md`](examples/sample-batch.md) 就是这份可直接使用的合成示例。

格式规则：

- 标题必须正好是 `##` + 一个空格 + 非空拼写；其他 `#` 开头的行会被拒绝（`malformed-heading`）。
- 释义正文内部的换行和缩进按字节保留。
- 典型批次 8–15 条，**上限 30 条**；单条释义上限 2000 字符；输入文件上限 256 KiB。
- 同一批次中拼写重复会被拒绝（`duplicate-spelling`）。

## 使用方法

三种模式共用同一条命令，只有 `--mode` 不同。`--allow-network` 是必须显式给出的开关；不给就不会创建任何网络传输层。

`--account-label` 是防止用错账号的人工护栏：标签必须包含 `secondary` / `test` / `副号` / `副账号` / `测试` 之一，且不得包含 `main` / `primary` / `owner` / `prod` / `production` / `主号` / `主账号` / `主账户` / `生产`。

> 该标签只能防止你在操作过程中把凭证拿错，**不能**证明 Token 属于哪个墨墨账号——公开 API 没有账号身份接口。真实运行前请先在墨墨 App 里人工确认你登录的是副账号。

### 1. 预览（不写入，先跑这个）

```bash
python3 scripts/interpretation_batch_importer.py --mode dry-run --input examples/sample-batch.md --account-label "secondary-test" --allow-network
```

`dry-run` 每条发出 2 个 GET，**0 个 POST**，不需要确认，也不会写任何东西。

### 2. 新建自建释义

```bash
python3 scripts/interpretation_batch_importer.py --mode create --input examples/sample-batch.md --account-label "secondary-test" --allow-network
```

### 3. 替换已有的自建释义

```bash
python3 scripts/interpretation_batch_importer.py --mode update --input examples/sample-batch.md --account-label "secondary-test" --allow-network
```

## Token 输入方式

运行后工具会用**隐藏输入**（`getpass`）询问 Token：

```text
Secondary/test-account Maimemo Token (hidden):
```

Token 只存在于当前进程内存中。本工具**刻意不支持**其他任何来源：

| 来源 | 是否支持 |
| --- | --- |
| 隐藏交互式输入 | ✅ 唯一支持的方式 |
| 命令行参数 / argv | ❌ 不支持（`--token` 会被拒绝，且参数值不会被回显） |
| 环境变量 | ❌ 不支持 |
| `.env` 文件 | ❌ 不支持 |
| 配置文件 | ❌ 不支持 |
| 剪贴板自动读取 | ❌ 不支持 |
| 系统钥匙串 / Keychain | ❌ v0.1.0 不支持 |

Token 永远不会进入 Git、日志、预览、运行报告或审阅包。工具只显示 Token 的 16 位 SHA-256 非敏感指纹，用于确认两次运行使用的是同一个凭证。

## preflight 判定结果

写入前，整批会先做一次完整 preflight，每条得到一个判定：

| 判定 | 含义 | 行为 |
| --- | --- | --- |
| `READY_CREATE` | 该词当前没有自建释义 | `create` 模式可写 |
| `READY_UPDATE` | 该词有且仅有一条本账号自建释义，内容与目标终态不同 | `update` 模式可写 |
| `ALREADY_MATCHING` | 已存在的记录与目标终态完全一致 | **零请求 no-op**，不发 POST |
| `BLOCK_EXISTING` | `create` 模式下已存在自建释义 | 阻断该词，不自动转 update |
| `BLOCK_MISSING` | `update` 模式下没有可替换的自建释义 | 阻断该词，不自动转 create |
| `BLOCK_AMBIGUOUS` | 返回多条自建释义，归属有歧义 | 阻断该词，绝不自动挑一条覆盖 |
| `BLOCK_ERROR` | 传输/HTTP/结构校验失败 | 阻断该词 |

**任何 `BLOCK_*` 都会在第一个 POST 之前中止整批。** `create` 不会退化成 `update`，`update` 也不会退化成 `create`。

## 各模式的具体行为

### create

- 该词已存在自建释义 → `BLOCK_EXISTING`，不覆盖、不新增第二条、不自动转 update。
- 只有全部条目都是 `READY_CREATE` 时才进入确认。

### update

- 没有自建释义 → `BLOCK_MISSING`。
- 恰好一条 → 预览并排展示**现有原文**和**拟写入内容**（两侧都不改写），确认后替换该条。
- 多条 → `BLOCK_AMBIGUOUS`，停止。
- 与目标终态完全一致 → `ALREADY_MATCHING`，**不发送任何请求**。整批全部匹配时是零写入成功。
- 更新目标记录 ID **只来自鉴权 GET 集合**，不接受来自命令行或 Markdown 的记录 ID；原始 ID 只在进程内使用，预览和报告只出现指纹。

## 确认门禁

预览之后、写入之前，需要一次**批级**确认（不是逐条确认）。确认串绑定了 operation、host、path、账号标签、Token 指纹、批次 digest、每条拼写、每条精确释义、标签、状态和条目数。预览之后任何条目发生变化，已输入的确认立即失效。

- `create` 显示一行 `CONFIRM BATCH INTERPRETATION CREATE: ...` 完整确认串。
- `update` 显示一行 31 字符的短令牌 `CONFIRM UPDATE <16 位小写十六进制>`；短令牌的 16 位十六进制是同一份完整绑定的 SHA-256 前缀，绑定内容一项没少。

把显示的那一行**原样粘贴**进隐藏提示，不要手工增删空格。

## 写入安全性

- 每个待写条目**最多一次 POST**；
- **任何情况下都不重试** POST；
- 每次 POST 后立即发起鉴权 GET 回读，逐字段核对正文、三标签集和 `PUBLISHED` 状态；
- POST 结果未知时只做一次内置 GET 恢复查询，**绝不重发**；
- 请求串行发出，无并发，最小间隔 1.6 秒（对齐官方公布的频控）；
- 只使用 `GET` 和 `POST`；没有 `PUT` / `PATCH` / `DELETE` 路径；
- 没有例句/短语请求路径；
- 不修改墨墨内置词典释义，只处理本账号自建记录；
- 中途失败即停止剩余条目，**不回滚、不删除**，并明确提示不要重发。

## 运行报告

每次运行会在被 Git 忽略的 `artifacts/private/` 下写一个小的脱敏 JSON 报告。

报告**包含**：模式、状态、批次 digest、时间戳、每条拼写、意图释义、固定标签/状态、preflight 判定、是否尝试 POST、回读结果、`voc_id` 与记录**指纹**，以及 update 的写前正文/标签/状态快照（这是你手工恢复被替换释义所需的本地证据）。

报告**不包含**：Token、`Authorization`、Cookie、账号标签、原始 `voc_id`、原始记录 ID、原始服务器响应。

它不是重放状态机——没有任何代码路径会读回它。回滚只能人工进行。

## 运行测试

无依赖，标准库 `unittest`，全程离线并由进程级 no-network guard 兜底：

```bash
MOMO_TEST_NETWORK_DISABLED=1 PYTHONPATH=tests/no_network_guard python3 -m unittest discover -s tests -p 'test_*.py'
```

guard 会把 `socket.socket`、`socket.create_connection` 和 `urllib.request.urlopen` 全部替换成抛异常的桩，因此测试**不可能**发出真实请求。

## 项目路线

1. [#2 验证 API 写入语义和跨账号标签可发现性](https://github.com/davidqyc/momo-moreEfficient/issues/2)（例句部分仍阻断）
2. [#3 构建批量释义录入 MVP](https://github.com/davidqyc/momo-moreEfficient/issues/3)（已完成，即本版本）
3. [#4 仅在阻断项通过后构建例句录入](https://github.com/davidqyc/momo-moreEfficient/issues/4)
4. [#5 构建桌面快速查词原型](https://github.com/davidqyc/momo-moreEfficient/issues/5)
5. [#6 完成公开仓库与首个可用版本准备](https://github.com/davidqyc/momo-moreEfficient/issues/6)
6. [#7 以真实维护和使用证据准备 Codex for Open Source 申请](https://github.com/davidqyc/momo-moreEfficient/issues/7)

## 不可妥协的安全基线

- 真实墨墨 Token、Cookie、账号标识、个人词库导出和私人例句不得进入 Git 历史。
- 写入工具默认 `dry-run`，真实写入前需要明确的批级确认。
- 不修改墨墨内置词典释义，只处理明确选中的用户自建内容。
- 每次写入后必须回读并核对；部分失败不得静默继续执行破坏性更新。
- 开发和测试只使用副账号；同一进程或配置中不得同时存在主账号凭证。

## 文档

- [Codex/Agent 工作规则](AGENTS.md)
- [产品需求与 API 验证计划](docs/product-and-api-plan.md)
- [Codex for Open Source 路线](docs/codex-for-open-source-plan.md)
- [决策记录](docs/decision-log.md)
- [变更日志](CHANGELOG.md)
- [安全说明](SECURITY.md)
- [贡献说明](CONTRIBUTING.md)

## 免责声明

本项目与墨墨背单词及其运营方无官方隶属或背书关系。项目只使用公开提供的接口，并遵守对应 API、内容与账号规则。Maimemo/墨墨相关名称和商标归其权利人所有。

本项目按 MIT 许可证发布，不提供任何担保。你对自己账号中的内容变更负责；请先在副账号上验证。

## 许可证

[MIT](LICENSE)
